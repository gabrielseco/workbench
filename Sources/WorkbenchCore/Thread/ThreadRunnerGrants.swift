import Foundation

extension ThreadRunner {
    /// What the user has allowed for the turn that starts next, read from the log.
    func grantsForNextTurn(config: Config) -> [String] {
        let events = (try? EventLogReader.read(at: project.eventsURL(threadID)).events) ?? []
        return GrantLedger(events: events).patternsForNextTurn(tools: config.tools)
    }

    /// The turn's request with the thread's grants added to what it may run. Read from the log before the turn
    /// starts, so a `once` grant is spent by the turn that follows it.
    func grantedTurnRequest(
        sessionID: UUID, resume: Bool, prompt: String, config: Config, goal: Goal, options: RunOptions
    ) -> TurnRequest {
        TurnRequest(
            sessionID: sessionID, resume: resume, budgetUSD: options.budgetOverride ?? goal.budgetUSD, prompt: prompt,
            appendSystemPrompt: PromptBuilder.rules(checkCommand: config.checkCommand), model: goal.model,
            extraAllowed: grantsForNextTurn(config: config))
    }
}
