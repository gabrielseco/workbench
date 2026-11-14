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

    /// The screenshots staged for the next message of the chat on screen.
    var chatStaging: AttachmentStaging { current.chatStaging }

    /// A chat turn is going in the thread on screen. A chat just started is held under no thread until its turn ends, so it counts
    /// once the window is on the thread the log shows with its turn open.
    var replyingHere: Bool {
        if current.replying { return true }
        guard let project, sessions[ThreadSession.Key(project: project, thread: nil)]?.replying == true,
            case .thread(let shown) = screen
        else { return false }
        return shown.state.chat?.open == true
    }

    /// A chat turn is going, in any thread: what a quit has to end.
    var chatReplying: Bool { sessions.values.contains(where: \.replying) }

    /// Says what is in the composer in the chat on screen. The text leaves the composer at once and comes back if core refuses the
    /// message (empty, too long, over a limit, no goal agent, the thread held, ended), so a refusal never loses what was typed. The
    /// screenshots staged for the chat go with it, and stay staged when it is refused.
    @discardableResult func sendChat() async -> Bool {
        guard let project, let thread = currentThread, !replyingHere, !drafting else { return false }
        let mine = threadSession(project, thread)
        let text = mine.chatDraft
        mine.chatDraft = ""
        mine.actionError = nil
        let started = await chatTurn(project, .existing(id: thread), text, attachments: mine.chatStaging.urls, in: mine)
        if started { mine.chatStaging.clear() }
        // What was typed while core was deciding stays, after what came back: a refusal loses neither.
        if !started { mine.chatDraft = mine.chatDraft.isEmpty ? text : text + "\n" + mine.chatDraft }
        return started
    }

    /// Starts a new chat with `message`, named from its first words, and opens it. Ends the active thread, as a drafted goal does (core's abandon keeps
    /// the branch and saves uncommitted work); a thread that is running refuses and the refusal is shown. A refusal returns false, so the card keeps the text. `attachments` are the screenshots sent
    /// with it; the caller clears what it staged when this returns true.
    @discardableResult func startChat(_ message: String, attachments: [URL] = []) async -> Bool {
        guard let project, !replyingHere, !drafting else { return false }
        // A chat with no thread yet is held under no thread; its errors are shown where the person is.
        let held = threadSession(project, nil)
        let shown = current
        shown.actionError = nil
        // The window follows the new chat; a refusal puts the person back on the thread they were reading.
        let picked = selectedThread
        selectedThread = nil
        let started = await chatTurn(
            project, .newThread(name: ThreadName.suggest(from: message)), message, attachments: attachments, in: held,
            errorsIn: shown)
        if !started, picked != nil {
            selectedThread = picked
            lastWatch = nil
            await reload()
        }
        return started
    }

    /// One turn through core, holding `session` as replying until it ends. True when core started the turn (it may still have ended
    /// badly: that is said on the thread); false when core refused it, with core's words in the session's `actionError`.
    private func chatTurn(
        _ project: Project, _ target: ChatTarget, _ message: String, attachments: [URL] = [], in held: ThreadSession,
        errorsIn shown: ThreadSession? = nil
    ) async -> Bool {
        let stop = DraftStop()
        setReplying(true, in: held, stop: stop)
        defer { setReplying(false, in: held) }
        let mine = generation
        let result: ChatResult
        do {
            result = try await actions.chat(project, target, message, attachments, stop)
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
        if case .newThread = target {
            (currentThread, lastWatch) = (nil, nil)
            showCreatedThread()
        }
        await reload()
        return true
    }

    /// Asks the chat turn of the thread on screen to end. It still ends with a recorded `stopped`.
    func stopChat() {
        if current.replying { return current.chatStop?.stop() ?? () }
        if let project { sessions[ThreadSession.Key(project: project, thread: nil)]?.chatStop?.stop() }
    }

    /// Stops the chat turn and waits until it has ended, at most `timeout`.
    func stopChatAndWait(timeout: Duration = .seconds(8)) async {
        guard chatReplying else { return }
        sessions.values.filter(\.replying).forEach { $0.chatStop?.stop() }
        let deadline = ContinuousClock.now + timeout
        while chatReplying, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Has the goal agent draft a goal from the conversation of the chat on screen, into that same thread. A draft that does not
    /// come out leaves the chat and its conversation as they were, with the reason shown.
    @discardableResult func makeChatGoal() async -> Bool {
        guard let project, let thread = currentThread, !drafting, !replyingHere else { return false }
        let held = threadSession(project, thread)
        held.actionError = nil
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
            // The reason stays on the chat it is about: the New goal card's "name a goal agent" offer is not this screen's.
            if mine == generation { held.actionError = "\(error)" }
            return false
        }
        await reload()
        return true
    }

    /// "Do it now": skips the conversation and drafts the goal from the person's words, as the New goal card's Advanced does.
    @discardableResult func doItNow(_ request: String) async -> Bool { await draftGoal(request: request) }
}
