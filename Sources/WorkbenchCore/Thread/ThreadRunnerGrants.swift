import Foundation

extension ThreadRunner {
    /// The turn's request with the thread's grants added to what it may run. Read from the log before the turn
    /// starts, so a `once` grant is spent by the turn that follows it.
    func grantedTurnRequest(
        sessionID: UUID, resume: Bool, prompt: String, config: Config, goal: Goal, options: RunOptions
    ) -> TurnRequest {
        let events = (try? EventLogReader.read(at: project.eventsURL(threadID)).events) ?? []
        return TurnRequest(
            sessionID: sessionID, resume: resume, budgetUSD: options.budgetOverride ?? goal.budgetUSD, prompt: prompt,
            appendSystemPrompt: PromptBuilder.rules(checkCommand: config.checkCommand), model: goal.model,
            extraAllowed: GrantLedger(events: events).patternsForNextTurn(tools: config.tools))
    }
}
