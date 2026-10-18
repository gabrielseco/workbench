import Foundation

public enum GrantScope: String, Sendable, Equatable {
    /// The next turn only.
    case once
    /// Every later turn of this thread.
    case thread
    /// Recorded so `grant` stops offering it; allows nothing.
    case never
}

/// One `grant.added` event.
public struct GrantRecord: Sendable, Equatable {
    public var seq: Int
    public var scope: GrantScope
    public var pattern: String
    /// The `claude` line whose denial this answers, when it answered one.
    public var denialSeq: Int?
}

/// What a pattern must be to be added to `--allowedTools`. The log is read back on every turn, so a hand-edited or
/// damaged `grant.added` must not be able to widen the tool set: it has to name a tool the project has, with a
/// command or path that is not a wildcard.
public enum GrantPattern {
    public static let maxLength = 2000

    /// Why `pattern` cannot be granted, nil when it can.
    public static func problem(_ pattern: String, available: [String]) -> String? {
        if pattern.isEmpty || pattern.count > maxLength { return "must be 1 to \(maxLength) characters" }
        if pattern.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "must be one line without control characters"
        }
        guard let open = pattern.firstIndex(of: "("), pattern.hasSuffix(")") else {
            return "must name a tool and what it may do, like Bash(git status:*), not a whole tool"
        }
        let tool = String(pattern[..<open])
        guard !tool.isEmpty, tool.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return "'\(tool)' is not a tool name"
        }
        guard available.contains(tool) else { return "\(tool) is not in this project's tool set" }
        var content = String(pattern[pattern.index(after: open)..<pattern.index(before: pattern.endIndex)])
        if content.hasSuffix(":*") { content.removeLast(2) }
        if content.allSatisfy({ $0.isWhitespace || $0 == "*" }) { return "must not allow everything" }
        return nil
    }
}

extension GrantPattern {
    /// The `[tools] denied` entry that covers `pattern`, nil when none does: the same pattern, a prefix rule
    /// (`Bash(git push:*)` covers `Bash(git push origin x)`), or the whole tool.
    public static func deniedBy(_ pattern: String, denied: [String]) -> String? {
        let (tool, content) = split(pattern)
        let target = content.hasSuffix(":*") ? String(content.dropLast(2)) : content
        return denied.first { entry in
            if entry == pattern || entry == tool { return true }
            let (entryTool, entryContent) = split(entry)
            guard entryTool == tool, entryContent.hasSuffix(":*") else { return false }
            return target.hasPrefix(String(entryContent.dropLast(2)))
        }
    }

    private static func split(_ pattern: String) -> (tool: String, content: String) {
        guard let open = pattern.firstIndex(of: "("), pattern.hasSuffix(")") else { return (pattern, "") }
        return (String(pattern[..<open]), String(pattern[pattern.index(after: open)..<pattern.index(before: pattern.endIndex)]))
    }
}

/// The grants of a thread, read from its `grant.added` events (the log is the state).
public struct GrantLedger: Sendable, Equatable {
    public private(set) var records: [GrantRecord] = []
    /// The `seq` of the latest `turn.started`: a `once` grant after it is for the turn that starts next.
    public private(set) var lastTurnStartSeq = 0

    public init(events: [Event]) {
        for event in events {
            switch event.kind {
            case .turnStarted:
                lastTurnStartSeq = event.seq
            case .grantAdded:
                guard let scope = event.data["scope"]?.stringValue.flatMap(GrantScope.init(rawValue:)),
                    let pattern = event.data["pattern"]?.stringValue
                else { continue }
                records.append(
                    GrantRecord(
                        seq: event.seq, scope: scope, pattern: pattern, denialSeq: event.data["denial_seq"]?.intValue))
            default:
                break
            }
        }
    }

    /// What to add to the project's allowed tools for the turn that starts next: the thread's grants and the
    /// `once` grants given since the last turn started. Invalid patterns and ones the project denies are left out.
    public func patternsForNextTurn(tools: ToolSet) -> [String] {
        // Records are read in order and the latest word on a pattern stands: `never` revokes what came before it,
        // and a grant after a `never` allows it again.
        var order: [String] = []
        var thread: Set<String> = []
        var once: [String: Int] = [:]
        for record in records {
            if !order.contains(record.pattern) { order.append(record.pattern) }
            switch record.scope {
            case .thread: thread.insert(record.pattern)
            case .once: once[record.pattern] = record.seq
            case .never:
                thread.remove(record.pattern)
                once[record.pattern] = nil
            }
        }
        return order.filter { pattern in
            (thread.contains(pattern) || (once[pattern] ?? 0) > lastTurnStartSeq)
                && GrantPattern.problem(pattern, available: tools.available) == nil
                && GrantPattern.deniedBy(pattern, denied: tools.denied) == nil && !tools.allowed.contains(pattern)
        }
    }

    /// Patterns the user turned down, so `grant` does not offer them again.
    public var refused: [String] {
        var latest: [String: GrantScope] = [:]
        for record in records { latest[record.pattern] = record.scope }
        return latest.filter { $0.value == .never }.map(\.key).sorted()
    }
}
