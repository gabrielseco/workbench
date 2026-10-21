import Foundation
import WorkbenchCore

extension Commands {
    static func printDoctor(_ report: DoctorReport) {
        out("claude:   \(report.claude ?? "NOT FOUND (\(report.claudePath))")")
        out("model:    \(report.model ?? "the claude CLI default (no `model` in the config)")")
        if let pattern = report.checkPattern {
            var note = ""
            if report.checkDenied {
                note = "  (but [tools].denied blocks it: a run cannot call the check)"
            } else if !report.bashAvailable {
                note = "  (but Bash is not in [tools].available)"
            }
            out("allowed:  \(pattern)" + note)
        }
        func show(_ name: String, _ step: DoctorStep, undeclared: String) {
            let label = name.padding(toLength: 10, withPad: " ", startingAt: 0)
            guard let command = step.command else { return out("\(label)none declared: \(undeclared)") }
            let seconds = step.durationMs.map { String(format: " in %.1fs", Double($0) / 1000) } ?? ""
            switch step.outcome {
            case .passed: out("\(label)passed\(seconds): \(command)")
            case .failed(let how): out("\(label)\(how)\(seconds): \(command)")
            case .timedOut: out("\(label)timed out\(seconds): \(command)")
            case .stopped: out("\(label)stopped\(seconds): \(command)")
            case .skipped(let why): out("\(label)skipped (\(why)): \(command)")
            case .notDeclared: out("\(label)none declared: \(undeclared)")
            }
            if !step.tail.isEmpty { out(step.tail) }
            if !step.hint.isEmpty { out("  \(step.hint)") }
        }
        show("setup:", report.setup, undeclared: "nothing is installed in a new worktree")
        show("check:", report.check, undeclared: "turns will end with no check evidence")
        for warning in report.reviewWarnings { out("review:   warning: \(warning)") }
        for note in report.copySkipped { out("copy:     not copied: \(note)") }
        if let verifier = report.verifier { printVerifier(verifier, base: report.base) }
        if let run = report.run { printRun(run) }
        printEditor(report.editor, problem: report.editorProblem)
    }

    static func printVerifier(_ verifier: DoctorVerifier, base: String) {
        let config = verifier.config
        let model = verifier.model ?? "the claude CLI default"
        if let skill = verifier.skill {
            let cut = skill.truncated ? ", cut at \(VerifierSkill.sizeLimit) bytes" : ""
            out("verifier: \(skill.path) at \(base) (\(skill.bytes) bytes, sha256 \(skill.sha256.prefix(12))\(cut))")
        } else {
            out("verifier: \(config.skill)")
        }
        out("  model:  \(model)")
        out("  tools:  \(config.tools.joined(separator: ", "))")
        out("  budget: $\(config.budgetUSD)  timeout: \(config.timeoutMin) min")
        if let problem = verifier.problem { out("  warning: \(problem)") }
        if let missing = verifier.screenRecording { out("  warning: \(missing)") }
    }

    static func printRun(_ run: DoctorRun) {
        out("run: \(run.config.command)")
        switch run.config.ready {
        case .url(let url): out("  ready:  \(url) answers (within \(run.config.readyTimeoutS)s)")
        case .line(let pattern): out("  ready:  a line matching /\(pattern)/ (within \(run.config.readyTimeoutS)s)")
        }
        if let problem = run.problem { out("  warning: \(problem)") }
    }
}
