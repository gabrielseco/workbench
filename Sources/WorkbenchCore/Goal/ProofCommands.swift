import Foundation

/// A proof that names a command the project's tool set would not let a run execute.
public struct ProofWarning: Sendable, Equatable {
    public var criterion: String
    public var command: String
    /// Why it cannot run, in words.
    public var reason: String
    /// The `[tools] allowed` entry that would permit it, when adding one would.
    public var suggestion: String?
    /// A `screenshot:` proof that nothing in the project can produce, rather than a command.
    public var isScreenshot = false

    public var line: String {
        if isScreenshot { return "[\(criterion)] proof is `\(command)`, but \(reason)" }
        var text = "[\(criterion)] proof names `\(command)`, which a run cannot execute: \(reason)"
        if let suggestion { text += ". Add \"\(suggestion)\" to [tools] allowed, or change the proof" }
        return text
    }
}

extension ProofWarning {
    /// What `approve` and `run` refuse with. Names the way out for a proof that only looks like a command.
    public static func refusal(_ warnings: [ProofWarning]) -> String {
        warnings.map(\.line).joined(separator: "\n")
            + "\nFix the tool set or the proof, or pass --allow-unrunnable-proofs if the proof is not meant "
            + "to be run by the run."
    }
}

/// Reads the commands a goal's proofs name and says which the allowlist denies (friction #30). A proof is
/// free text, so only a backticked span that looks like a command counts: its first word is an
/// executable the tool set already mentions, or a path into the repository.
public enum ProofCommands {
    /// `verifierSkillAvailable` is whether the verifier's skill is in the base; false means nothing makes a
    /// screenshot proof.
    public static func warnings(goal: Goal, config: Config, verifierSkillAvailable: Bool = true) -> [ProofWarning] {
        let allowed = config.effectiveAllowedTools.compactMap(bashPattern)
        let denied = config.tools.denied.compactMap(bashPattern)
        let known = Set((allowed + denied).compactMap { $0.literal.split(separator: " ").first.map(String.init) })
        let bashAvailable = config.tools.available.contains("Bash")

        var out: [ProofWarning] = []
        var seen = Set<String>()
        for criterion in goal.criteria {
            if let name = ScreenshotProof.name(in: criterion.proof), !(config.verifier != nil && verifierSkillAvailable) {
                out.append(
                    ProofWarning(
                        criterion: criterion.id, command: "screenshot: \(name)",
                        reason: "the project has no verifier skill (off, or not in the base commit), so "
                            + "nothing makes \(name).png: set one in the config, commit the skill, or change the proof",
                        suggestion: nil, isScreenshot: true))
                continue
            }
            for span in spans(in: criterion.proof).flatMap(parts(of:)) {
                guard let first = span.split(separator: " ").first.map(String.init),
                    known.contains(first) || isRepositoryPath(first),
                    seen.insert("\(criterion.id)\u{0}\(span)").inserted
                else { continue }
                if !bashAvailable {
                    out.append(
                        ProofWarning(
                            criterion: criterion.id, command: span, reason: "the Bash tool is not available",
                            suggestion: nil))
                } else if let hit = denied.first(where: { $0.matches(span) }) {
                    out.append(
                        ProofWarning(
                            criterion: criterion.id, command: span,
                            reason: "it is denied by `Bash(\(hit.display))`", suggestion: nil))
                } else if !allowed.contains(where: { $0.matches(span) }) {
                    out.append(
                        ProofWarning(
                            criterion: criterion.id, command: span, reason: "it is not in [tools] allowed",
                            suggestion: "Bash(\(span):*)"))
                }
            }
        }
        return out
    }

    /// Text between single backticks, on one line.
    static func spans(in text: String) -> [String] {
        text.matches(of: #/`([^`\n]+)`/#).map { String($0.1).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `a && b | c` is three commands, and the permission layer judges each. Only these four joiners are
    /// split; anything else stays one command.
    static func parts(of span: String) -> [String] {
        span.split(omittingEmptySubsequences: true, whereSeparator: { "&|;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func isRepositoryPath(_ word: String) -> Bool {
        word.hasPrefix("./") || word.hasPrefix("scripts/") || word.hasPrefix("bin/")
    }

    private struct Pattern {
        /// The command text, or "" for a bare `Bash`, which allows or denies everything.
        var literal: String
        var prefix: Bool

        var display: String { prefix ? "\(literal):*" : literal }

        func matches(_ command: String) -> Bool {
            if literal.isEmpty { return true }
            if !prefix { return command == literal }
            return command == literal || command.hasPrefix(literal + " ")
        }
    }

    /// `Bash`, `Bash(cmd)` or `Bash(cmd:*)`; other tools are not commands.
    private static func bashPattern(_ entry: String) -> Pattern? {
        if entry == "Bash" { return Pattern(literal: "", prefix: true) }
        guard entry.hasPrefix("Bash("), entry.hasSuffix(")") else { return nil }
        let inner = String(entry.dropFirst(5).dropLast())
        if inner.hasSuffix(":*") { return Pattern(literal: String(inner.dropLast(2)), prefix: true) }
        return Pattern(literal: inner, prefix: false)
    }
}
