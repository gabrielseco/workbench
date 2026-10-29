import Foundation

/// One file the verifier left in the proof directory, as `verifier.ended` lists it.
public struct VerifierFile: Sendable, Equatable {
    public var name: String
    public var bytes: Int
    public var sha256: String
}

/// What one verifier turn came to. A failed verifier is a result, not a thrown error: it is advisory, so a
/// missing `claude`, a timeout or a budget stop only mean there is no report this time.
public struct VerifierReport: Sendable, Equatable {
    public var turn: Int
    public var ok: Bool
    /// Why it did not finish well; nil when `ok`.
    public var reason: String?
    public var costUSD: Double?
    public var durationMs: Int
    /// Files it added to, or changed in, the turn's proof directory.
    public var files: [VerifierFile]
    /// What it said at the end, bounded. Never read as a pass.
    public var report: String
}

/// The request to the verifier and the reading of its answer. Pure: no process, no files.
/// docs/plan/P10-skill-verifier.md has the rules; the numbers refer to them.
public enum Verifier {
    public static let reportLimit = 4096
    public static let maxFiles = 200
    public static let maxOutputBytes = 8 << 20

    // MARK: Request

    /// The bare tool names for `--tools` (what exists at all) out of the permission patterns for `--allowedTools`.
    public static func availableTools(_ patterns: [String]) -> [String] {
        var seen: Set<String> = []
        return patterns.compactMap { pattern in
            let name = String(pattern.prefix { $0 != "(" })
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// The argv, prompt last. Always `--safe-mode` and `--disable-slash-commands` (rule 3), whatever the project's
    /// `safe_mode` says: the skill is text in the prompt. The tools are the project's `[verifier] tools` and
    /// nothing else (rule 2); the project's `[tools] denied` still applies on top.
    ///
    /// `--add-dir` names the turn's proof directory: `--restricted` confines the file tools to the worktree, and the
    /// proof directory is in the thread's folder, so without it the verifier could write a screenshot (through the
    /// project's helper) but not `Read` it back to look.
    public static func arguments(
        config: Config, verifier: VerifierConfig, prompt: String, proofDirectory: URL, sessionID: UUID = UUID()
    ) -> [String] {
        var args = [
            "-p", "--output-format", "json", "--permission-prompts", "none", "--restricted",
            "--session-id", sessionID.uuidString.lowercased(),
            "--max-budget-usd", NSDecimalNumber(decimal: verifier.budgetUSD).stringValue,
            "--safe-mode", "--disable-slash-commands", "--add-dir", proofDirectory.path,
        ]
        if let model = config.verifierModel { args += ["--model", model] }
        args += ["--tools"] + availableTools(verifier.tools)
        args += ["--allowedTools"] + verifier.tools
        if !config.tools.denied.isEmpty { args += ["--disallowedTools"] + config.tools.denied }
        args += ["--", prompt]
        return args
    }

    /// What the verifier is told: its role, the skill as the project wrote it, the goal's criteria, and where to
    /// leave the proof. The paths are real here (the model needs them), unlike in the judge's brief.
    public static func prompt(
        skill: VerifierSkill, goal: Goal, proofDirectory: URL, threadID: String, goalPath: String, app: RunningApp? = nil
    ) -> String {
        var parts: [String] = [
            """
            You are the verifier for one piece of work in this checkout. You did not write it. Follow the skill \
            below to build and drive the app to the state each criterion of the goal needs, look at what it shows, \
            and say for each criterion whether it holds. Use only the tools you were given.
            Rules:
            - Leave every screenshot in the proof directory, named as the criterion's `proof: screenshot: <name>` \
            says (`<name>.png`). Do not save files anywhere else the project did not ask for.
            - Never start, stop or change the installed copy of the app; use the throwaway build the skill describes.
            - Report only on criteria whose proof is a screenshot or that you can see on screen. A `test:` or \
            `command:` proof is run by Workbench's check, not by you: do not say it is unverified because you cannot \
            run it.
            - Finish with a short report: one line per criterion, its id, `holds` or `does not hold`, and what you \
            saw. Your words are a note for the person reviewing; they decide nothing.
            """
        ]
        parts.append("## Environment\n\n" + environmentLines(proofDirectory, threadID, goalPath, app: app))
        if app != nil {
            parts.append(
                """
                ## The app

                Workbench has already started the project's app (`[run]`) and will stop it when you finish. Drive that \
                instance; do not start, restart or stop one yourself.
                """)
        }
        parts.append("## Goal: \(oneLine(goal.title))\n\n\(goal.request)")
        let criteria = goal.criteria.map { "- [\($0.id)] \(oneLine($0.text))\n  - proof: \(oneLine($0.proof))" }
        parts.append("## Criteria\n\n" + criteria.joined(separator: "\n"))
        if !goal.outOfScope.isEmpty {
            parts.append("## Out of scope\n\n" + goal.outOfScope.map { "- \(oneLine($0))" }.joined(separator: "\n"))
        }
        parts.append("## Skill (\(skill.path))\n\n\(skill.text)")
        return parts.joined(separator: "\n\n")
    }

    static func environmentLines(
        _ proofDirectory: URL, _ threadID: String, _ goalPath: String, app: RunningApp? = nil
    ) -> String {
        var lines = [
            "- WORKBENCH_PROOF_DIR=\(proofDirectory.path)",
            "- WORKBENCH_THREAD=\(threadID)",
            "- WORKBENCH_GOAL=\(goalPath)",
        ]
        if let app {
            lines.append("- WORKBENCH_RUN_PID=\(app.pid)")
            lines.append("- WORKBENCH_PORT=\(app.port)")
            if let url = app.url { lines.append("- WORKBENCH_RUN_URL=\(url)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The variables the verifier's tools see, on top of the allowlisted environment.
    public static func environment(
        base: [String: String], proofDirectory: URL, threadID: String, goalPath: String, app: RunningApp? = nil
    ) -> [String: String] {
        var env = base
        if let app {
            env["WORKBENCH_RUN_PID"] = String(app.pid)
            env["WORKBENCH_PORT"] = String(app.port)
            env["PORT"] = String(app.port)
            if let url = app.url { env["WORKBENCH_RUN_URL"] = url }
        }
        env["WORKBENCH_PROOF_DIR"] = proofDirectory.path
        env["WORKBENCH_THREAD"] = threadID
        env["WORKBENCH_GOAL"] = goalPath
        return env
    }

    /// The app Workbench started from `[run]`, as the verifier is told about it.
    public struct RunningApp: Sendable, Equatable {
        public var pid: Int32
        public var port: Int
        public var url: String?
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    // MARK: Answer

    /// What `claude -p --output-format json` printed: the final text and cost, or why there is none.
    struct Answer: Equatable {
        var text: String?
        var costUSD: Double?
        var failure: String?
    }

    /// Reads the one JSON object. A budget stop is told apart from other errors by the result's `subtype`.
    static func parse(output: String, budget: Decimal) -> Answer {
        guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Answer(text: nil, costUSD: nil, failure: "the answer was not JSON") }
        let cost = (object["total_cost_usd"] as? NSNumber)?.doubleValue
        if object["is_error"] as? Bool == true {
            let subtype = (object["subtype"] as? String) ?? ""
            if subtype.localizedCaseInsensitiveContains("budget") {
                return Answer(
                    text: nil, costUSD: cost,
                    failure: "stopped at the budget ($\(NSDecimalNumber(decimal: budget).stringValue))")
            }
            return Answer(text: nil, costUSD: cost, failure: "claude reported an error")
        }
        guard let text = object["result"] as? String else {
            return Answer(text: nil, costUSD: cost, failure: "the answer had no result")
        }
        // A run that ends with nothing to say has not verified anything; it must not count as having done so.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Answer(text: nil, costUSD: cost, failure: "the answer was empty")
        }
        return Answer(text: text, costUSD: cost, failure: nil)
    }

    /// The end of a report, cut at a line, so a long answer cannot fill the log.
    static func bounded(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > reportLimit else { return trimmed }
        let marker = "[report cut at \(reportLimit) bytes]"
        let window = Array(trimmed.utf8.prefix(reportLimit - marker.utf8.count - 1))
        let cut = window.lastIndex(of: UInt8(ascii: "\n")) ?? window.count
        let kept = String(decoding: window[..<cut], as: UTF8.self)
        return kept.isEmpty ? marker : kept + "\n" + marker
    }

    /// Why a `claude` run produced no answer to read, nil when it ended on its own with status 0.
    static func processProblem(_ exit: ProcessExit?, timeout: TimeInterval) -> String? {
        guard let exit else { return "claude did not report how it ended" }
        switch exit.cause {
        case .stopped: return "the verifier was stopped"
        case .timedOut: return "claude did not finish within \(Int(timeout))s"
        case .natural: break
        }
        switch exit.termination {
        case .exited(0): return nil
        case .exited(let code): return "claude exited with status \(code)"
        case .signaled(let signal): return "claude was ended by signal \(signal)"
        case .lost: return "claude ended in a way that was not recorded"
        }
    }

    // MARK: Recovery

    /// Ends what a verifier left behind (the app, also detached) and closes its `verifier.started`. Run by every
    /// command that opens the log, so the next one of any kind finds it closed. Returns whether there was one.
    @discardableResult
    static func recoverOrphan(log: EventLogWriter, worktree: URL) async throws -> Bool {
        guard await log.hasOpenVerifier else { return false }
        OrphanSweeper.sweep(inside: worktree)
        try await log.recoverOrphanedVerifier()
        return true
    }
}
