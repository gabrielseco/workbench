import Foundation
import WorkbenchCore

/// The chat before a goal (P22 slice 6c): the store's side of what the chat screen does. Core runs every turn and draft; this holds
/// what the window knows about them, per thread, so an answer for a thread that is no longer on screen lands on its own session.
extension ProjectStore {
    /// The composer of the chat on screen.
    var chatDraft: String {
        get { current.chatDraft }
        set { current.chatDraft = newValue }
    }

    /// A chat turn is going, in any thread: core allows one at a time.
    var chatReplying: Bool { sessions.values.contains(where: \.replying) }

    /// Says what is in the composer in the chat on screen. The text leaves the composer at once and comes back if core refuses the
    /// message (empty, too long, over a limit, no goal agent, the thread held, ended), so a refusal never loses what was typed.
    @discardableResult func sendChat() async -> Bool {
        guard let project, let thread = currentThread, !chatReplying, !drafting else { return false }
        let mine = threadSession(project, thread)
        let text = mine.chatDraft
        mine.chatDraft = ""
        mine.actionError = nil
        let started = await chatTurn(project, .existing(id: thread), text, in: mine)
        if !started, mine.chatDraft.isEmpty { mine.chatDraft = text }
        return started
    }

    /// Starts a new chat with `message`, named from its first words, and opens it. Never ends another thread: while one is active core
    /// refuses and the refusal is shown. A refusal returns false, so the card keeps the text.
    @discardableResult func startChat(_ message: String) async -> Bool {
        guard let project, !chatReplying, !drafting else { return false }
        // A chat with no thread yet is held under no thread; its errors are shown where the person is.
        let held = threadSession(project, nil)
        let shown = current
        shown.actionError = nil
        selectedThread = nil
        let started = await chatTurn(
            project, .newThread(name: ThreadName.suggest(from: message)), message, in: held, errorsIn: shown)
        return started
    }

    /// One turn through core, holding `session` as replying until it ends. True when core started the turn (it may still have ended
    /// badly: that is said on the thread); false when core refused it, with core's words in the session's `actionError`.
    private func chatTurn(
        _ project: Project, _ target: ChatTarget, _ message: String, in held: ThreadSession, errorsIn shown: ThreadSession? = nil
    ) async -> Bool {
        let stop = DraftStop()
        setReplying(true, in: held, stop: stop)
        defer { setReplying(false, in: held) }
        let mine = generation
        let result: ChatResult
        do {
            result = try await actions.chat(project, target, message, stop)
        } catch {
            if mine == generation { (shown ?? held).actionError = "\(error)" }
            return false
        }
        guard mine == generation else { return true }
        // The turn is on the thread it ran in, which for a new chat is the one core made.
        let home = threadSession(project, result.id)
        switch result.end {
        case "ok": break
        case "stopped": home.actionError = "The turn was stopped."
        default:
            let cost = result.costUSD.map { String(format: " ($%.4f spent)", $0) } ?? ""
            home.actionError = "No reply\(cost): \(result.failure ?? result.end)."
        }
        if case .newThread = target { (currentThread, lastWatch) = (nil, nil) }
        await reload()
        return true
    }

    /// Asks the chat turn that is going, in any thread, to end. It still ends with a recorded `stopped`.
    func stopChat() {
        sessions.values.first { $0.replying }?.chatStop?.stop()
    }

    /// Stops the chat turn and waits until it has ended, at most `timeout`.
    func stopChatAndWait(timeout: Duration = .seconds(8)) async {
        guard chatReplying else { return }
        stopChat()
        let deadline = ContinuousClock.now + timeout
        while chatReplying, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Has the goal agent draft a goal from the conversation of the chat on screen, into that same thread. A draft that does not
    /// come out leaves the chat and its conversation as they were, with the reason shown.
    @discardableResult func makeChatGoal() async -> Bool {
        guard let project, let thread = currentThread, !drafting, !chatReplying else { return false }
        let held = threadSession(project, thread)
        held.actionError = nil
        goalAgentOff = false
        let stop = DraftStop()
        (drafting, draftStop) = (true, stop)
        defer { (drafting, draftStop) = (false, nil) }
        let mine = generation
        do {
            let result = try await actions.draftFromChat(project, thread, stop)
            guard mine == generation else { return false }
            guard result.id != nil else {
                held.actionError = Self.draftFailure(result, stopped: stop.wasRequested)
                return false
            }
        } catch {
            if mine == generation {
                goalAgentOff = (error as? GoalDraftRefusal) == .noGoalAgent
                held.actionError = goalAgentOff ? nil : "\(error)"
            }
            return false
        }
        await reload()
        return true
    }

    /// "Do it now": skips the conversation and drafts the goal from the person's words, as the New goal card's Advanced does.
    @discardableResult func doItNow(_ request: String) async -> Bool { await draftGoal(request: request) }
}
