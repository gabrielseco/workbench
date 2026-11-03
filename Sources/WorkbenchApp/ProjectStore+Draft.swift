import Foundation
import WorkbenchCore

/// The new-thread screen's work: a quick goal written from what the person wrote, or one the goal agent drafts from it.
extension ProjectStore {
    /// Writes a quick goal from the request as typed and opens the new thread on it. Nothing is drafted or spent; a refusal leaves
    /// the project as it was, so the card keeps the text.
    @discardableResult func quickGoal(request raw: String, attachments: [URL] = []) async -> Bool {
        guard let project, !starting, !drafting else { return false }
        (actionError, goalAgentOff) = (nil, false)
        let request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        drafting = true
        defer { drafting = false }
        let mine = generation
        do {
            _ = try await actions.quickGoal(project, ThreadName.suggest(from: request), request, attachments)
        } catch {
            if mine == generation { actionError = "\(error)" }
            return false
        }
        guard mine == generation else { return false }
        // A new goal is the thread to show, as it always has been, not the old one picked in the list.
        (currentThread, lastWatch, selectedThread) = (nil, nil, nil)
        showCreatedThread()
        await reload()
        return true
    }

    /// Has the goal agent draft a goal from what the person wrote and opens the new thread on it. The drafter is read-only and
    /// approves nothing; a draft that does not come out leaves the project as it was, so the sheet keeps the text.
    @discardableResult func draftGoal(request raw: String, name typedName: String? = nil, attachments: [URL] = []) async -> Bool {
        guard let project, !starting, !drafting else { return false }
        (actionError, goalAgentOff) = (nil, false)
        let request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = typedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = typed.isEmpty ? ThreadName.suggest(from: request) : typed
        let stop = DraftStop()
        (drafting, draftStop) = (true, stop)
        defer { (drafting, draftStop) = (false, nil) }
        let mine = generation
        do {
            let result = try await actions.draftGoal(project, name, request, attachments, stop)
            guard mine == generation else { return false }
            guard result.id != nil else {
                actionError = Self.draftFailure(result, stopped: stop.wasRequested)
                return false
            }
        } catch {
            goalAgentOff = (error as? GoalDraftRefusal) == .noGoalAgent
            // The sheet offers to name a goal agent instead of showing the refusal, and the screen behind it stays quiet.
            actionError = goalAgentOff ? nil : "\(error)"
            return false
        }
        // A new goal is the thread to show, as it always has been, not the old one picked in the list.
        (currentThread, lastWatch, selectedThread) = (nil, nil, nil)
        showCreatedThread()
        await reload()
        return true
    }

    /// What a draft that did not come out says: stopped, or why there was none and what it cost.
    static func draftFailure(_ result: GoalDraftResult, stopped: Bool) -> String {
        let cost = result.costUSD.map { String(format: " ($%.4f spent)", $0) } ?? ""
        return stopped
            ? "Drafting was stopped. Nothing was written."
            : "No draft\(cost): \(result.failure ?? "no proposal"). Nothing was written."
    }

    /// Stops the drafter that is running, if any.
    func stopDrafting() { draftStop?.stop() }

    /// Stops the drafter and waits until its run has ended, at most `timeout`: the drafter's agent runs in a process group of its
    /// own, and its kill after a refused SIGTERM happens after `stop` returns, so a quit that does not wait can outlive it.
    func stopDraftingAndWait(timeout: Duration = .seconds(8)) async {
        guard drafting else { return }
        stopDrafting()
        let deadline = ContinuousClock.now + timeout
        while drafting, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Names `provider` as the goal agent in the project's config, then drafts. A config that cannot take it is left as it was.
    @discardableResult func enableGoalDrafting(
        _ provider: AgentProviderID, request: String, name: String? = nil, attachments: [URL] = []
    ) async -> Bool {
        guard let project, !drafting else { return false }
        do {
            try await actions.enableGoalAgent(project, provider)
        } catch {
            (actionError, goalAgentOff) = ("\(error)", false)
            return false
        }
        return await draftGoal(request: request, name: name, attachments: attachments)
    }
}
