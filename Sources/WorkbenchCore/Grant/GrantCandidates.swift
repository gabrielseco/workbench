import Foundation

public enum GrantStatus: Sendable, Equatable {
    case open
    /// Allowed by a `grant.added` that still counts for the next turn.
    case granted(GrantScope)
    /// Turned down with `--never`.
    case refused
}

/// A denied command a person can decide about, numbered the way `workbench grant` shows it.
public struct GrantCandidate: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        /// `2` for a plain command, `2.1` for the first part of a compound.
        public var number: String
        public var command: String
        public var level: DeniedCommandAssessment.Level
        public var reasons: [String]
        public var pattern: String?
        public var status: GrantStatus
    }

    public var number: Int
    public var tool: String
    /// The command, path or URL as the model sent it.
    public var input: String?
    public var turns: [Int]
    /// The `claude` lines that carry the denial.
    public var seqs: [Int]
    public var assessment: DeniedCommandAssessment
    public var parts: [Part]
    public var status: GrantStatus

    /// What `--never` records for something that has no pattern to grant.
    static func neverPattern(tool: String, text: String) -> String { "\(tool)(\(text))" }
    public var wholePattern: String { Self.neverPattern(tool: tool, text: input ?? "") }
}

/// The same denied call, however often and in whichever turns it happened.
private struct DeniedGroup {
    var tool: String
    var input: String?
    var turns: [Int] = []
    var seqs: [Int] = []
}

public enum GrantCandidates {
    private static let inputKeys = ["command", "file_path", "path", "notebook_path", "url", "pattern", "query"]

    /// The denied calls of a thread, grouped by tool and whole input, in the order they first happened. The
    /// numbers depend only on the log, so `grant 3` means the same thing after other grants are recorded.
    public static func derive(events: [Event]) -> [GrantCandidate] {
        // A turn's last result line is the one whose denials count (as in `ThreadState`).
        var lastResult: [Int: (seq: Int, denials: [JSONValue])] = [:]
        for event in events where event.kind == .claude && event.data["type"]?.stringValue == "result" {
            if case .array(let denials)? = event.data["permission_denials"] {
                lastResult[event.turn] = (event.seq, denials)
            }
        }
        var groups: [DeniedGroup] = []
        var index: [String: Int] = [:]
        for turn in lastResult.keys.sorted() {
            guard let found = lastResult[turn] else { continue }
            for denial in found.denials {
                guard let tool = denial["tool_name"]?.stringValue else { continue }
                let input = inputKeys.lazy.compactMap { denial["tool_input"]?[$0]?.stringValue }.first { !$0.isEmpty }
                let key = tool + "\u{0}" + (input ?? "")
                let at = index[key] ?? groups.count
                if index[key] == nil {
                    index[key] = at
                    groups.append(DeniedGroup(tool: tool, input: input))
                }
                if !groups[at].turns.contains(turn) { groups[at].turns.append(turn) }
                groups[at].seqs.append(found.seq)
            }
        }
        let ledger = GrantLedger(events: events)
        return groups.enumerated().map { offset, group in
            candidate(number: offset + 1, group: group, ledger: ledger)
        }
    }

    private static func candidate(
        number: Int, group: DeniedGroup, ledger: GrantLedger
    ) -> GrantCandidate {
        let assessment = DeniedCommandClassifier.classify(tool: group.tool, input: group.input)
        let parts = assessment.parts.enumerated().map { offset, part in
            GrantCandidate.Part(
                number: assessment.isCompound ? "\(number).\(offset + 1)" : "\(number)", command: part.command,
                level: part.level, reasons: part.reasons, pattern: part.pattern,
                status: status(of: part.pattern ?? GrantCandidate.neverPattern(tool: group.tool, text: part.command), in: ledger))
        }
        let whole = GrantCandidate.neverPattern(tool: group.tool, text: group.input ?? "")
        let overall = assessment.isCompound ? status(of: whole, in: ledger) : (parts.first?.status ?? .open)
        return GrantCandidate(
            number: number, tool: group.tool, input: group.input, turns: group.turns, seqs: group.seqs,
            assessment: assessment, parts: parts, status: overall)
    }

    private static func status(of pattern: String, in ledger: GrantLedger) -> GrantStatus {
        for record in ledger.records.reversed() where record.pattern == pattern {
            switch record.scope {
            case .never: return .refused
            case .thread: return .granted(.thread)
            case .once: if record.seq > ledger.lastTurnStartSeq { return .granted(.once) }
            }
        }
        return .open
    }
}
