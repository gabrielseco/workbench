import Foundation

extension ThreadRunner {
    // MARK: Setup

    /// The install step, once, before the first turn. Not after a turn has started (a send-back never
    /// repeats it), and not again once it has passed; a failed one is simply tried again by the next run.
    func runSetupIfNeeded(
        lastTurn: Int, config: Config, goal: Goal, worktree: URL, log: EventLogWriter, options: RunOptions
    ) async throws {
        guard lastTurn == 0, let command = config.setupCommand, !setupPassed() else { return }
        try await runSetup(command: command, config: config, goal: goal, worktree: worktree, log: log, options: options)
    }

    private func setupPassed() -> Bool {
        guard let contents = try? EventLogReader.read(at: project.eventsURL(threadID)) else { return false }
        return contents.events.contains { $0.kind == .setupRan && $0.data["result"]?.stringValue == "passed" }
    }

    private func runSetup(
        command: String, config: Config, goal: Goal, worktree: URL, log: EventLogWriter, options: RunOptions
    ) async throws {
        let runner = SetupRunner(
            command: command, worktree: worktree, environment: config.childEnvironment(from: options.parentEnvironment),
            timeout: options.setupTimeoutOverride ?? SetupRunner.defaultTimeout, killGrace: options.killGrace)
        notify(.setupStarted(command: command))
        defer { currentRun = nil }
        let report = try await runner.run(outputURL: project.setupOutputURL(threadID), log: log) { [self] process in
            await attach(process)
        }
        notify(.setupRan(report))
        guard report.result == .passed else {
            let tail = SetupRunner.tail(of: project.setupOutputURL(threadID))
            throw RunnerError.setupFailed(
                command: command, how: report.how, output: tail, hint: Self.envHint(report))
        }
    }

    /// A setup that works in the person's shell and fails here is usually a variable the child environment
    /// (an allowlist) dropped, and the output names the tool, not the environment (friction #32).
    static func envHint(_ report: SetupReport) -> String {
        guard report.result == .failed, report.exitCode != nil || report.signal != nil else { return "" }
        return "If it passes in your own shell, the child environment may be dropping a variable your version "
            + "manager sets (mise: MIX_HOME, MIX_ARCHIVES): add it to `env_pass` in .workbench/config.toml."
    }

    /// Whether the verifier's skill is there, read as the verifier will: from the recorded base once the worktree
    /// exists, from the branch name before that.
    func verifierSkillAvailable(config: Config, goal: Goal) async -> Bool {
        let ref = await recordedBaseCommit(goal: goal) ?? goal.base
        return await VerifierSkill.isAvailable(config: config, git: git, repo: project.root, ref: ref)
    }

    /// A run needs an approved goal, and proofs the tool set can execute. The config is not in the approval
    /// hash, so the proofs are judged again here, where a turn gets paid for.
    static func requireRunnable(
        goal: Goal, config: Config, options: RunOptions, verifierSkillAvailable: Bool = true
    ) throws {
        guard goal.approval == .approved else { throw RunnerError.goalNotApproved(goal.approval) }
        let unrunnable = ProofCommands.warnings(goal: goal, config: config, verifierSkillAvailable: verifierSkillAvailable)
        if !unrunnable.isEmpty, !options.allowUnrunnableProofs {
            throw RunnerError.unrunnableProofs(ProofWarning.refusal(unrunnable))
        }
    }
}
