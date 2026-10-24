import Foundation

/// Who verifies one criterion. Only the project's own check is run by Workbench, so only a proof that is
/// that check can be passed or failed here; everything else is for a person (docs/spec/goal-file.md).
public struct CriterionStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case passed, failed, manual
        /// A screenshot proof whose files the latest turn's verifier left: for a person to look at,
        /// not a pass.
        case evidence
        /// A screenshot proof with a file missing. Never read as met.
        case missing
    }

    public var id: String
    public var state: State
    /// The backticked commands of the proof, for a person to run. Empty when the proof names none.
    public var commands: [String]
    /// Why a proof that names the check is still for a person, or which run backs a verdict.
    public var note: String?
    /// The proof as written, for a row that has no command to show.
    public var proof: String
    /// The recorded file that backs an `evidence` row, relative to the thread directory (the first, when several).
    public var file: String? { files.first }
    /// Every recorded file that backs an `evidence` row, in the order the proof names them.
    public var files: [String] = []
    /// For a screenshot proof: each name it asks for and whether the file is there, in order.
    public var screenshots: [Screenshot] = []

    public struct Screenshot: Sendable, Equatable {
        public var name: String
        /// Relative to the thread directory when present.
        public var path: String?
        public var present: Bool { path != nil }
    }

    /// What a person sees in the first column.
    public var label: String {
        switch state {
        case .passed: "✔ passed"
        case .failed: "✘ failed"
        case .manual: "you check"
        case .evidence: "see screenshot"
        case .missing: "✘ missing"
        }
    }
}

public enum CriteriaStatus {
    /// - Parameters:
    ///   - check: the latest completed check, nil when none ran. Its recorded `command` is what a proof
    ///     is matched against, so a config changed since the run cannot turn a result into someone else's.
    ///   - lastTurn: the newest turn; a check from an earlier turn says nothing about the current work.
    public static func evaluate(
        criteria: [Criterion], check: Review.Check?, lastTurn: Int,
        verifier: Review.Verifier? = nil, proofAvailable: (ProofFile) -> Bool = { _ in true }
    ) -> [CriterionStatus] {
        let proof = Review.ProofSet(verifier: verifier)
        return criteria.map { criterion in
            if let names = ScreenshotProof.names(in: criterion.proof) {
                return screenshot(
                    criterion, names: names, proof: proof, lastTurn: lastTurn, available: proofAvailable)
            }
            if let names = TestProof.names(in: criterion.proof) {
                return named(criterion, names: names, check: check, lastTurn: lastTurn)
            }
            let spans = ProofCommands.spans(in: criterion.proof)
            var status = CriterionStatus(
                id: criterion.id, state: .manual, commands: spans, note: nil, proof: criterion.proof)
            // Without a recorded check there is no command to match; the summary line says no check ran.
            guard let check else { return status }
            guard let ran = check.command, isTheCheck(proof: criterion.proof, spans: spans, command: ran) else {
                // Fallback for proofs that are not typed: prose that names only tests the check ran.
                if let tests = check.tests, !tests.truncated,
                    let names = TestProof.namesInProse(criterion.proof, known: tests) {
                    return named(criterion, names: names, check: check, lastTurn: lastTurn)
                }
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

    /// A proof that names tests: decided by the tests the latest turn's finished check saw, else left to a person.
    static func named(_ criterion: Criterion, names: [String], check: Review.Check?, lastTurn: Int) -> CriterionStatus {
        var status = CriterionStatus(
            id: criterion.id, state: .manual, commands: [], note: nil, proof: criterion.proof)
        guard let check else { return status }
        guard check.turn == lastTurn else {
            status.note = "the check ran after turn \(check.turn), not the latest turn \(lastTurn)"
            return status
        }
        guard check.result == "passed" || check.result == "failed" else {
            status.note = "the check ended \(check.result.replacingOccurrences(of: "_", with: " "))"
            return status
        }
        guard let tests = check.tests, !tests.truncated else {
            status.note = check.tests == nil ? "the check's output listed no tests" : "the check's test list was cut"
            return status
        }
        guard let state = TestProof.verdict(for: names, in: tests) else {
            status.note = "a named test did not appear in the check's output (turn \(check.turn))"
            return status
        }
        status.state = state
        status.note = state == .passed
            ? "named test ran in the check, turn \(check.turn)" : "named test failed in the check, turn \(check.turn)"
        return status
    }

    /// Screenshots are shown when the latest turn's proof (the verifier's) has `<name>.png` for every name the criterion
    /// asks for.
    static func screenshot(
        _ criterion: Criterion, names: [String], proof: Review.ProofSet?, lastTurn: Int, available: (ProofFile) -> Bool
    ) -> CriterionStatus {
        var status = CriterionStatus(
            id: criterion.id, state: .missing, commands: [], note: nil, proof: criterion.proof)
        let wanted = names.map { ScreenshotProof.fileName(for: $0) }
        let list = wanted.joined(separator: ", ")
        guard let proof else {
            status.note = "no verifier has run, so \(list) was not produced"
            return status
        }
        guard proof.turn == lastTurn else {
            status.note = "the proof is of turn \(proof.turn), not the latest turn \(lastTurn)"
            return status
        }
        var problems: [String] = []
        for (name, fileName) in zip(names, wanted) {
            guard let file = proof.files.first(where: { $0.name == fileName }) else {
                status.screenshots.append(.init(name: name, path: nil))
                problems.append("no \(fileName) in the proof (turn \(proof.turn))")
                continue
            }
            guard available(file) else {
                status.screenshots.append(.init(name: name, path: nil))
                problems.append("\(fileName) was recorded in turn \(proof.turn), but the file is gone, unreadable or changed")
                continue
            }
            status.screenshots.append(.init(name: name, path: file.path))
        }
        status.files = status.screenshots.compactMap(\.path)
        guard problems.isEmpty else {
            status.note = problems.joined(separator: "; ")
            return status
        }
        status.state = .evidence
        status.note = "\(proof.source), turn \(proof.turn)"
        return status
    }

    /// `Criteria: 1 passed · 0 failed · 4 for you to check`, plus a word when no check backs a verdict.
    public static func summary(_ statuses: [CriterionStatus], check: Review.Check?) -> String {
        let passed = statuses.filter { $0.state == .passed }.count
        let failed = statuses.filter { $0.state == .failed }.count
        let evidence = statuses.filter { $0.state == .evidence }.count
        let missing = statuses.filter { $0.state == .missing }.count
        let manual = statuses.count - passed - failed - evidence - missing
        var text = "Criteria: \(passed) passed · \(failed) failed · \(manual) for you to check"
        if evidence > 0 { text += " · \(evidence) with a screenshot" }
        if missing > 0 { text += " · \(missing) missing" }
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
            if status.state == .evidence { for file in status.files { lines.append("         \(file)") } }
            if status.state == .missing {
                for shot in status.screenshots where shot.present { lines.append("         \(shot.path ?? "")") }
                if let note = status.note { lines.append("         \(note)") }
            }
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
            case .evidence:
                todo = "look at the screenshot" + (status.note.map { " (\(cell($0)))" } ?? "")
            case .missing:
                todo = "no screenshot" + (status.note.map { ": \(cell($0))" } ?? "")
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
