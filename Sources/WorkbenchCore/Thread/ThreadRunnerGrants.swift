import Foundation

extension ThreadRunner {
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
    ) -> AgentRequest {
        var limits = AgentLimits(timeout: options.timeoutOverride ?? TimeInterval(goal.turnTimeoutMin) * 60)
        limits.killGrace = options.killGrace
        let agent = config.resolvedRunAgent(goalModel: goal.model)
        if agent.provider == .codex {
            // One fresh process: no session, no model, no tool patterns, and the rules are already at the top of the prompt.
            return AgentRequest(
                provider: .codex, prompt: prompt, workingDirectory: worktree, outputDirectory: outputDirectory,
                policy: .scopedCoding, spend: spend(for: goal, options: options), purpose: .coding,
                environment: options.parentEnvironment, limits: limits)
        }
        let session: AgentSessionIntent =
            resume
            ? .resume(AgentSessionHandle(provider: .claude, purpose: .coding, value: sessionID))
            : .start(proposed: sessionID)
        return AgentRequest(
            provider: .claude, model: agent.model, prompt: prompt, workingDirectory: worktree,
            outputDirectory: outputDirectory, policy: .scopedCoding,
            spend: spend(for: goal, options: options), session: session, purpose: .coding,
            environment: options.parentEnvironment, limits: limits,
            rules: PromptBuilder.rules(checkCommand: config.checkCommand), grants: grantsForNextTurn(config: config))
    }
}
