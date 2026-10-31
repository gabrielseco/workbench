import Foundation

extension ThreadRunner {
    /// The thread's log, opened for this run. A Claude session handed to Herdr works in this worktree without holding the log: it
    /// is a run already, so this one is refused.
    func openLog() throws -> EventLogWriter {
        if ThreadStore(project: project).holdsHerdrSession(id: threadID) { throw RunnerError.herdrSessionRunning }
        do { return try EventLogWriter.open(at: project.eventsURL(threadID)) } catch EventLogError.alreadyOpen {
            throw RunnerError.alreadyRunning
        }
    }

    /// What the user has allowed for the turn that starts next, read from the log.
    func grantsForNextTurn(config: Config) -> [String] {
        let events = (try? EventLogReader.read(at: project.eventsURL(threadID)).events) ?? []
        return GrantLedger(events: events).patternsForNextTurn(tools: config.tools)
    }

    /// A hard cap (the `--budget` override first) or none for a `timeout_only` goal, which has no cap to override.
    func spend(for goal: Goal, options: RunOptions) -> AgentSpend {
        guard let budget = goal.budgetUSD else { return .timeoutOnly }
        return .hardCap(options.budgetOverride ?? budget)
    }

    /// The turn's request with the thread's grants added to what it may run. Read from the log before the turn
    /// starts, so a `once` grant is spent by the turn that follows it.
    func grantedAgentRequest(
        sessionID: String, resume: Bool, prompt: String, config: Config, goal: Goal, worktree: URL,
        outputDirectory: URL, options: RunOptions
    ) throws -> AgentRequest {
        var limits = AgentLimits(timeout: options.timeoutOverride ?? TimeInterval(goal.turnTimeoutMin) * 60)
        limits.killGrace = options.killGrace
        let agent = config.resolvedRunAgent(goalModel: goal.model)
        if agent.provider == .codex {
            // One fresh process: no session, no tool patterns, and the rules are already at the top of the prompt.
            return AgentRequest(
                provider: .codex, model: agent.model, prompt: prompt, workingDirectory: worktree,
                outputDirectory: outputDirectory, policy: .scopedCoding, spend: spend(for: goal, options: options),
                purpose: .coding,
                environment: options.parentEnvironment, limits: limits, reasoningEffort: agent.reasoningEffort)
        }
        let session: AgentSessionIntent =
            resume
            ? .resume(AgentSessionHandle(provider: .claude, purpose: .coding, value: sessionID))
            : .start(proposed: sessionID)
        var request = AgentRequest(
            provider: .claude, model: agent.model, prompt: prompt, workingDirectory: worktree,
            outputDirectory: outputDirectory, policy: .scopedCoding,
            spend: spend(for: goal, options: options), session: session, purpose: .coding,
            environment: options.parentEnvironment, limits: limits,
            rules: PromptBuilder.rules(checkCommand: config.checkCommand), grants: grantsForNextTurn(config: config),
            reasoningEffort: agent.reasoningEffort)
        request.readDirectories = try readDirectories(config, goal: goal)
        return request
    }

    /// Refuses a run whose `read_also` names a folder it cannot be given: the config says it, so it holds or nothing starts.
    func requireReadAlso(_ config: Config, goal: Goal) throws { _ = try readDirectories(config, goal: goal) }

    /// The other checkouts this turn may read, resolved now: a folder that was there when the run began and is gone before a
    /// later turn refuses that turn, rather than starting it without the access the config promised.
    /// The project's `read_also` first, then the goal's own, each folder once.
    func readDirectories(_ config: Config, goal: Goal) throws -> [URL] {
        switch ReadAlso.resolve(config: config.readAlso, goal: goal.readAlso, projectRoot: project.root) {
        case .success(let found): return found
        case .failure(let problem): throw RunnerError.invalidReadAlso("\(problem)")
        }
    }
}
