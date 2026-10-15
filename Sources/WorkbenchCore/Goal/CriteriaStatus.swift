import Foundation

/// Who verifies one criterion. Only the project's own check is run by Workbench, so only a proof that is
/// that check can be passed or failed here; everything else is for a person (docs/spec/goal-file.md).
public struct CriterionStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case passed, failed, manual
    }

    public var id: String
    public var state: State
    /// The backticked commands of the proof, for a person to run. Empty when the proof names none.
    public var commands: [String]
    /// Why a proof that names the check is still for a person, or which run backs a verdict.
    public var note: String?
    /// The proof as written, for a row that has no command to show.
    public var proof: String

    /// What a person sees in the first column.
    public var label: String {
        switch state {
        case .passed: "✔ passed"
        case .failed: "✘ failed"
        case .manual: "you check"
        }
    }
}

public enum CriteriaStatus {
    /// - Parameters:
    ///   - checkCommand: the config's `check_command`, nil when the project has none.
    ///   - check: the latest completed check, nil when none ran.
    ///   - lastTurn: the newest turn; a check from an earlier turn says nothing about the current work.
    public static func evaluate(
        criteria: [Criterion], checkCommand: String?, check: Review.Check?, lastTurn: Int
    ) -> [CriterionStatus] {
        criteria.map { criterion in
            let spans = ProofCommands.spans(in: criterion.proof)
            var status = CriterionStatus(
                id: criterion.id, state: .manual, commands: spans, note: nil, proof: criterion.proof)
            guard let checkCommand, isTheCheck(proof: criterion.proof, spans: spans, command: checkCommand) else {
                return status
            }
            guard let check else {
                status.note = "the check has not run"
                return status
            }
            guard check.turn == lastTurn else {
                status.note = "the check ran after turn \(check.turn), not the latest turn \(lastTurn)"
                return status
            }
            switch check.result {
            case "passed":
                status.state = .passed
                status.note = "check, turn \(check.turn)"
            case "failed":
                status.state = .failed
                status.note = "check, turn \(check.turn)" + (check.exitCode.map { ", exit \($0)" } ?? "")
            default:
                status.note = "the check ended \(check.result.replacingOccurrences(of: "_", with: " "))"
            }
            return status
        }
    }

    /// `Criteria: 1 passed · 0 failed · 4 for you to check`, plus a word when no check backs a verdict.
    public static func summary(_ statuses: [CriterionStatus], check: Review.Check?) -> String {
        let passed = statuses.filter { $0.state == .passed }.count
        let failed = statuses.filter { $0.state == .failed }.count
        let manual = statuses.count - passed - failed
        var text = "Criteria: \(passed) passed · \(failed) failed · \(manual) for you to check"
        if check == nil { text += " (check did not run)" }
        return text
    }

    // MARK: Which proofs are the check

    /// Words a proof may add around the check command and still be only "the check passes". Anything else,
    /// such as "after adding a bad line", is a further step Workbench cannot prove, so it stays manual.
    private static let filler: Set<String> = [
        "exits", "exit", "0", "zero", "passes", "pass", "passed", "green", "succeeds", "succeed", "runs",
        "clean", "cleanly", "on", "a", "the", "checkout", "with", "and", "no", "errors", "is", "stays",
        "still", "check", "full", "project's", "completes", "code", "status", "ok",
    ]

    static func isTheCheck(proof: String, spans: [String], command: String) -> Bool {
        guard spans.count == 1, spans[0] == command else { return false }
        let rest = proof.replacingOccurrences(of: "`\(command)`", with: " ")
        let words = rest.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        return words.allSatisfy { filler.contains(String($0)) }
    }
}

extension CriteriaStatus {
    /// Terminal lines for the table, one row per criterion and its commands beneath.
    public static func render(_ statuses: [CriterionStatus]) -> [String] {
        var lines: [String] = []
        for status in statuses {
            var row = "  [\(status.id)] \(status.label)"
            if status.state != .manual, let note = status.note { row += "  (\(note))" }
            lines.append(row)
            if status.state == .manual {
                if let note = status.note { lines.append("         \(note)") }
                if status.commands.isEmpty {
                    lines.append("         see the proof above")
                } else {
                    for command in status.commands { lines.append("         run: \(command)") }
                }
            }
        }
        return lines
    }

    /// A markdown table for the pull request. Pass or fail only: no check output reaches it.
    public static func markdown(_ statuses: [CriterionStatus], oneLine: (String) -> String) -> String {
        func cell(_ text: String) -> String {
            oneLine(text).replacingOccurrences(of: "|", with: "\\|")
        }
        var rows = ["| | Status | What to do |", "|---|---|---|"]
        for status in statuses {
            let todo: String
            switch status.state {
            case .passed, .failed:
                todo = "Workbench's check run" + (status.note.map { " (\($0))" } ?? "")
            case .manual:
                var parts = status.commands.map { "`\(cell($0))`" }
                if parts.isEmpty { parts = [cell(status.proof)] }
                if let note = status.note { parts.append("_\(cell(note))_") }
                todo = parts.joined(separator: "<br>")
            }
            rows.append("| \(status.id) | \(status.label) | \(todo) |")
        }
        return rows.joined(separator: "\n")
    }
}
