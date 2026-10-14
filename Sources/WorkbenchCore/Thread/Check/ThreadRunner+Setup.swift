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
            throw RunnerError.setupFailed(command: command, how: report.how, output: tail)
        }
    }
}
