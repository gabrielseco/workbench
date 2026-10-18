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
        var out: [String] = []
        for record in records where record.scope == .thread || (record.scope == .once && record.seq > lastTurnStartSeq) {
            guard GrantPattern.problem(record.pattern, available: tools.available) == nil,
                !tools.denied.contains(record.pattern), !tools.allowed.contains(record.pattern), !out.contains(record.pattern)
            else { continue }
            out.append(record.pattern)
        }
        return out
    }

    /// Patterns the user turned down, so `grant` does not offer them again.
    public var refused: [String] { records.filter { $0.scope == .never }.map(\.pattern) }
}
