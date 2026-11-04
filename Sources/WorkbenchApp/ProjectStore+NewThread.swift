import Foundation
import WorkbenchCore

/// The new-thread screen's side of the store (design parity 6): how it opens and closes, and what its three buttons do.
extension ProjectStore {
    /// Every "new goal" button opens the new-thread screen.
    func beginNewGoal() { openNewThread() }

    func openNewThread() {
        guard project != nil else { return }
        actionError = nil
        goalAgentOff = false
        newThread = true
    }

    func closeNewThread() {
        newThread = false
        actionError = nil
        goalAgentOff = false
    }

    private var newThreadRequest: String { newThreadText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Send: a free chat from what is typed, with the staged screenshots. The text stays when core refuses.
    @discardableResult func sendNewThread(attachments: [URL] = []) async -> Bool {
        guard !newThreadRequest.isEmpty else { return false }
        let made = await startChat(newThreadText, attachments: attachments)
        if made { newThreadText = "" }
        return made
    }

    /// Do it now: a goal drafted from the words and the screenshots, as the popover's Advanced does.
    @discardableResult func draftNewThread(attachments: [URL]) async -> Bool {
        guard !newThreadRequest.isEmpty else { return false }
        let made = await draftGoal(request: newThreadText, attachments: attachments)
        if made { newThreadText = "" }
        return made
    }

    /// Write it as the goal: a quick goal from the words as typed, with no agent, as the popover's Quick does.
    @discardableResult func quickNewThread(attachments: [URL]) async -> Bool {
        guard !newThreadRequest.isEmpty else { return false }
        let made = await quickGoal(request: newThreadText, attachments: attachments)
        if made { newThreadText = "" }
        return made
    }

    /// Names a goal agent in the config and then drafts, for a project that had none.
    @discardableResult func draftNewThread(naming provider: AgentProviderID, attachments: [URL]) async -> Bool {
        guard !newThreadRequest.isEmpty else { return false }
        let made = await enableGoalDrafting(provider, request: newThreadText, attachments: attachments)
        if made { newThreadText = "" }
        return made
    }
}
