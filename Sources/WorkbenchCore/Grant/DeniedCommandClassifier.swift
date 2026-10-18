import Foundation

/// How risky it is to let a run use a command it was denied, by rules and not by a model, so the same text
/// always gets the same answer (docs/plan/P13-grant.md). When unsure it rates up.
public struct DeniedCommandAssessment: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable, Equatable {
        case safe, caution, unsafe
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// One simple command of the denied text.
    public struct Part: Sendable, Equatable {
        /// The command as written.
        public var command: String
        public var level: Level
        public var reasons: [String]
        /// The tool pattern that would allow this part, nil when it cannot be granted as written.
        public var pattern: String?
    }

    /// The worst of the parts; a compound is at least `caution`.
    public var level: Level
    public var isCompound: Bool
    public var parts: [Part]
    /// Why the text as a whole is not what to grant.
    public var problems: [String]

    public var reasons: [String] { problems + parts.flatMap(\.reasons) }
    /// What can be granted: the patterns of the parts that have one. For a compound, the parts and not the whole.
    public var grantable: [String] { parts.compactMap(\.pattern) }
}

public enum DeniedCommandClassifier {
    public static func classify(tool: String, input: String?) -> DeniedCommandAssessment {
        guard tool == "Bash" else { return classifyOther(tool: tool, input: input) }
        let split = ShellSplit.split(input ?? "")
        guard !split.segments.isEmpty else {
            return DeniedCommandAssessment(
                level: .caution, isCompound: false, parts: [],
                problems: ["the denial did not record a command"])
        }
        var problems: [String] = []
        if split.isUnbalanced { problems.append("a quote or escape is not closed") }
        let isCompound = split.segments.count > 1
        if isCompound { problems.append("several commands in one; allow each part on its own") }
        var parts = split.segments.map(assess)
        if split.isUnbalanced {
            parts = parts.map {
                var part = $0
                part.pattern = nil
                return part
            }
        }
        var level = parts.map(\.level).max() ?? .caution
        if isCompound || split.isUnbalanced { level = max(level, .caution) }
        return DeniedCommandAssessment(
            level: level, isCompound: isCompound, parts: parts, problems: problems)
    }

    private static func classifyOther(tool: String, input: String?) -> DeniedCommandAssessment {
        let name = String(tool.prefix(60))
        let outside = input.map(escapesWorktree) ?? false
        let level: DeniedCommandAssessment.Level = outside ? .unsafe : .caution
        let reason =
            outside
            ? "\(name) of a path outside the worktree" : "\(name) is not in this project's tool set"
        let patternable = input.flatMap {
            $0.isEmpty || $0.contains(")") || $0.contains("\n") ? nil : "\(name)(\($0))"
        }
        let part = DeniedCommandAssessment.Part(
            command: input ?? name, level: level, reasons: [reason], pattern: patternable)
        return DeniedCommandAssessment(level: level, isCompound: false, parts: [part], problems: [])
    }

    static func escapesWorktree(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~") || path.split(separator: "/").contains("..")
    }
}
