import Foundation

extension ThreadRunner {
    /// What the user has allowed for the turn that starts next, read from the log.
    func grantsForNextTurn(config: Config) -> [String] {
        let events = (try? EventLogReader.read(at: project.eventsURL(threadID)).events) ?? []
        return GrantLedger(events: events).patternsForNextTurn(tools: config.tools)
    }

    /// The turn's request with the thread's grants added to what it may run. Read from the log before the turn
    /// starts, so a `once` grant is spent by the turn that follows it.
    func grantedAgentRequest(
        sessionID: String, resume: Bool, prompt: String, config: Config, goal: Goal, worktree: URL,
        outputDirectory: URL, options: RunOptions
    ) -> AgentRequest {
        let session: AgentSessionIntent =
            resume
            ? .resume(AgentSessionHandle(provider: .claude, purpose: .coding, value: sessionID))
            : .start(proposed: sessionID)
        var limits = AgentLimits(timeout: options.timeoutOverride ?? TimeInterval(goal.turnTimeoutMin) * 60)
        limits.killGrace = options.killGrace
        return AgentRequest(
            provider: .claude, model: config.resolvedRunAgent(goalModel: goal.model).model, prompt: prompt,
            workingDirectory: worktree,
            outputDirectory: outputDirectory, policy: .scopedCoding,
            spend: .hardCap(options.budgetOverride ?? goal.budgetUSD), session: session, purpose: .coding,
            environment: options.parentEnvironment, limits: limits,
            rules: PromptBuilder.rules(checkCommand: config.checkCommand), grants: grantsForNextTurn(config: config))
    }
}
