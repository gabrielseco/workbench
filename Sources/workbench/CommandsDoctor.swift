import Foundation
import WorkbenchCore

extension Commands {
    /// `doctor --json`: the resolved agents with what is wrong or limited about each, what the active goal was
    /// approved for, and the declared steps' results. Documented in `docs/spec/cli-json.md`.
    static func doctorJSON(_ report: DoctorReport) -> JSONValue {
        func step(_ step: DoctorStep) -> JSONValue {
            let result: String
            switch step.outcome {
            case .passed: result = "passed"
            case .failed: result = "failed"
            case .timedOut: result = "timed_out"
            case .stopped: result = "stopped"
            case .skipped: result = "skipped"
            case .notDeclared: result = "not_declared"
            }
            return [
                "command": step.command.map { .string($0) } ?? .null, "result": .string(result),
                "duration_ms": step.durationMs.map { .int($0) } ?? .null,
            ]
        }
        func issue(_ issue: DoctorAgentIssue) -> JSONValue {
            ["kind": .string(issue.kind), "severity": .string(issue.severity.rawValue), "message": .string(issue.message)]
        }
        let approved = report.approvedFor.map(approvedJSON) ?? .null
        return [
            "v": .int(jsonVersion), "base": .string(report.base), "passed": .bool(report.passed),
            "claude": report.claude.map { .string($0) } ?? .null, "model": report.model.map { .string($0) } ?? .null,
            "thread": report.thread.map { .string($0) } ?? .null, "approved_for": approved,
            "spend_policy": report.thread == nil ? .null : .string(report.spendLine == nil ? "hard_cap" : "timeout_only"),
            "agents": .array(
                report.agents.map { agent in
                    [
                        "role": .string(agent.role.rawValue),
                        "provider": agent.resolved.map { .string("\($0.provider)") } ?? .null,
                        "model": agent.resolved?.model.map { .string($0) } ?? .null,
                        "reasoning_effort": agent.resolved?.reasoningEffort.map { .string($0) } ?? .null,
                        "note": agent.note.map { .string($0) } ?? .null, "issues": .array(agent.issues.map(issue)),
                    ]
                }),
            "problems": .array(
                report.agentProblems.map { problem in
                    ["role": .string(problem.role.rawValue), "kind": .string(problem.kind), "message": .string(problem.message)]
                }),
            "setup": step(report.setup), "check": step(report.check),
            "review_warnings": .array(report.reviewWarnings.map { .string($0) }),
            "cleanup_problem": report.cleanupProblem.map { .string($0) } ?? .null,
        ]
    }

    static func printDoctor(_ report: DoctorReport) {
        out("claude:   \(report.claude ?? "NOT FOUND (\(report.claudePath))")")
        out("model:    \(report.model ?? "the provider's default (no `model` in [agents.run])")")
        for agent in report.agents {
            let label = "agent \(agent.role.rawValue):".padding(toLength: 14, withPad: " ", startingAt: 0)
            guard let resolved = agent.resolved else { out("\(label)none (\(agent.note ?? ""))"); continue }
            let note = agent.note.map { " (\($0))" } ?? ""
            let effort = resolved.reasoningEffort.map { ", effort \($0)" } ?? ""
            out("\(label)\(AgentUse.describe(provider: "\(resolved.provider)", model: resolved.model))\(effort)\(note)")
            for issue in agent.issues { out("  \(issue.severity.rawValue): \(issue.message)") }
        }
        if let thread = report.thread, let approved = report.approvedFor {
            out("approved: \(thread) for \(approved.description)")
        }
        if let spend = report.spendLine { out("spend:    \(spend)") }
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
