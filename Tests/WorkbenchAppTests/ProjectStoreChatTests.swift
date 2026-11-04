import AppKit
import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptChatStoreFixtures: [AppFixture] = []

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

/// The store's side of the chat (P22 slice 6c): what it asks core, what it keeps per thread, and what it says when core refuses.
@MainActor @Suite struct ProjectStoreChatTests {
    private let first = "g-2026-11-03-first"
    private let second = "g-2026-11-03-second"

    private func fixture() async throws -> AppFixture {
        let fixture = try await AppFixture()
        keptChatStoreFixtures.append(fixture)
        return fixture
    }

    private func addChat(_ fixture: AppFixture, _ id: String, ended: Bool = true) throws {
        try FileManager.default.createDirectory(at: fixture.project.threadDirectory(id), withIntermediateDirectories: true)
        try fixture.append(id, .threadCreated, data: ["kind": "chat", "repo": .string(fixture.project.root.path)])
        try fixture.append(id, .chatMessage, data: ["role": "user", "text": "could uploads retry?"])
        try fixture.append(id, .chatMessage, data: ["role": "assistant", "text": "What after five tries?"])
        if ended { try fixture.append(id, .chatEnded, data: ["ok": true, "cost_usd": 0.01]) }
    }

    private func opened(
        chat: @escaping GoalActions.Chat = { _, _, _, _, _ in throw GoalActions.Unset() },
        draftFromChat: @escaping GoalActions.DraftFromChat = { _, _, _ in throw GoalActions.Unset() },
        draftGoal: @escaping GoalActions.DraftGoal = { _, _, _, _, _ in throw GoalActions.Unset() },
        chats: [String] = ["g-2026-11-03-first"]
    ) async throws -> (ProjectStore, AppFixture) {
        let fixture = try await fixture()
        for id in chats { try addChat(fixture, id) }
        let actions = GoalActions(draftGoal: draftGoal, chat: chat, draftFromChat: draftFromChat)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return (store, fixture)
    }

    nonisolated private static func ok(_ id: String, end: String = "ok", failure: String? = nil) -> ChatResult {
        ChatResult(id: id, reply: end == "ok" ? "Yes." : nil, end: end, failure: failure, costUSD: 0.01, provider: .claude)
    }

    // MARK: Sending

    @Test func aMessageGoesToTheChatOnScreenAndTheComposerEmptiesWhileTheTurnRuns() async throws {
        let gate = Gate()
        let seen = Seen()
        let id = first
        let (store, _) = try await opened(chat: { _, target, message, _, _ in
            seen.add("\(target)|\(message)")
            await gate.wait()
            return ChatResult(id: id, reply: "Yes.", end: "ok", costUSD: 0.01, provider: .claude)
        })
        #expect(store.currentThread == first)
        store.chatDraft = "and then?"
        let sending = Task { await store.sendChat() }
        while !store.chatReplying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.chatDraft.isEmpty, "the text left the composer when the turn started")
        #expect(store.current.replying == true && !store.current.isIdle, "a replying chat is never dropped")
        await gate.open()
        #expect(await sending.value)
        #expect(!store.chatReplying && store.actionError == nil)
        #expect(seen.all == ["existing(id: \"\(first)\")|and then?"])
    }

    @Test func everyRefusalKeepsTheTextAndShowsCoresOwnWords() async throws {
        let refusals: [ChatRefusal] = [
            .emptyMessage, .messageTooLong, .tooManyTurns, .conversationTooLong, .overBudget, .noGoalAgent, .busy,
            .tooManyImages, .attachment("a.png is not an image"),
            .ended("accepted"), .running(pid: 7), .doctorRunning, .spend("cap"), .hasGoal("x"),
        ]
        for refusal in refusals {
            let (store, _) = try await opened(chat: { _, _, _, _, _ in throw refusal })
            store.chatDraft = "typed words"
            #expect(await store.sendChat() == false)
            #expect(store.chatDraft == "typed words", "\(refusal)")
            #expect(store.actionError == "\(refusal)" && !store.chatReplying)
        }
    }

    @Test func aTurnThatEndsBadlySaysSoOnTheThreadAndStillCountsAsStarted() async throws {
        let id = first
        struct Ending { var end: String, failure: String?, said: String }
        let endings = [
            Ending(end: "stopped", failure: nil, said: "The turn was stopped."),
            Ending(end: "timeout", failure: "ran 300 s", said: "No reply ($0.0100 spent): ran 300 s."),
            Ending(end: "failed", failure: "exit 1", said: "No reply ($0.0100 spent): exit 1."),
        ]
        for ending in endings {
            let (end, failure, said) = (ending.end, ending.failure, ending.said)
            let (store, _) = try await opened(chat: { _, _, _, _, _ in Self.ok(id, end: end, failure: failure) })
            store.chatDraft = "hello"
            #expect(await store.sendChat())
            #expect(store.chatDraft.isEmpty && store.actionError == said, "\(end): \(store.actionError ?? "nil")")
        }
    }

    @Test func aSecondTurnWhileOneRunsIsNotStarted() async throws {
        let gate = Gate()
        let seen = Seen()
        let id = first
        let (store, _) = try await opened(chat: { _, _, message, _, _ in
            seen.add(message)
            await gate.wait()
            return ChatResult(id: id, reply: "Yes.", end: "ok", provider: .claude)
        })
        store.chatDraft = "one"
        let sending = Task { await store.sendChat() }
        while !store.chatReplying { try await Task.sleep(for: .milliseconds(10)) }
        store.chatDraft = "two"
        #expect(await store.sendChat() == false)
        #expect(await store.startChat("three") == false)
        #expect(store.chatDraft == "two", "what was typed meanwhile stays")
        await gate.open()
        _ = await sending.value
        #expect(seen.all == ["one"])
    }

    @Test func whatWasTypedWhileCoreDecidedStaysWhenItRefuses() async throws {
        let gate = Gate()
        let (store, _) = try await opened(chat: { _, _, _, _, _ in
            await gate.wait()
            throw ChatRefusal.busy
        })
        store.chatDraft = "first message"
        let sending = Task { await store.sendChat() }
        while !store.chatReplying { try await Task.sleep(for: .milliseconds(10)) }
        store.chatDraft = "second, typed meanwhile"
        await gate.open()
        #expect(await sending.value == false)
        #expect(store.chatDraft == "first message\nsecond, typed meanwhile")
    }

    @Test func aNewChatCountsAsReplyingOnceTheWindowIsOnItsThread() async throws {
        let gate = Gate()
        let (store, fixture) = try await opened(
            chat: { _, _, _, _, _ in
                await gate.wait()
                return ChatResult(id: "g-2026-11-03-new", reply: "Yes.", end: "ok", provider: .claude)
            }, chats: [])
        #expect(!store.replyingHere)
        let starting = Task { await store.startChat("a new idea") }
        while !store.chatReplying { try await Task.sleep(for: .milliseconds(10)) }
        // Core made the thread and wrote the message; the window follows the active chat.
        try addChat(fixture, "g-2026-11-03-new", ended: false)
        await store.reload()
        #expect(store.currentThread == "g-2026-11-03-new" && store.replyingHere)
        await gate.open()
        #expect(await starting.value)
        #expect(!store.chatReplying && !store.replyingHere)
    }

    // MARK: Starting

    @Test func startingAChatNamesItFromItsFirstWordsAndNeverAbandonsAnotherThread() async throws {
        let seen = Seen()
        let id = first
        let (store, _) = try await opened(chat: { _, target, message, _, _ in
            seen.add("\(target)|\(message)")
            if case .newThread = target, message.hasPrefix("refuse") { throw ChatRefusal.activeThread(id) }
            return ChatResult(id: id, reply: "Yes.", end: "ok", provider: .claude)
        })
        #expect(await store.startChat("Add retry with backoff\nto uploads"))
        #expect(seen.all == ["newThread(name: \"add-retry-with-backoff\")|Add retry with backoff\nto uploads"])
        #expect(await store.startChat("refuse this") == false)
        #expect(store.actionError == "\(ChatRefusal.activeThread(id))")
    }

    @Test func aRefusedNewChatLeavesThePersonOnTheThreadTheyWereReading() async throws {
        let a = first
        let b = second
        let (store, _) = try await opened(
            chat: { _, _, _, _, _ in throw ChatRefusal.activeThread(a) }, chats: [a, b])
        await store.select(thread: a)
        #expect(store.currentThread == a)
        #expect(await store.startChat("a new idea") == false)
        #expect(store.currentThread == a && store.selectedThread == a)
        #expect(store.actionError == "\(ChatRefusal.activeThread(a))", "the refusal is on the thread that is shown")
    }

    // MARK: A thread that is no longer on screen

    @Test func theAnswerForAThreadThatIsNoLongerOnScreenLandsOnItsOwnSession() async throws {
        let gate = Gate()
        let a = first
        let b = second
        let (store, _) = try await opened(
            chat: { _, _, _, _, _ in
                await gate.wait()
                return ChatResult(id: a, reply: nil, end: "timeout", failure: "slow", provider: .claude)
            }, chats: [a, b])
        await store.select(thread: a)
        store.chatDraft = "hello"
        let sending = Task { await store.sendChat() }
        while !store.chatReplying { try await Task.sleep(for: .milliseconds(10)) }
        await store.select(thread: b)
        #expect(store.currentThread == b && store.actionError == nil)
        store.chatDraft = "draft for b"
        await gate.open()
        _ = await sending.value
        #expect(store.currentThread == b && store.actionError == nil, "B does not show A's outcome")
        #expect(store.chatDraft == "draft for b")
        await store.select(thread: a)
        #expect(store.actionError == "No reply: slow.", "A shows it when the window comes back")
        await store.select(thread: b)
        #expect(store.chatDraft == "draft for b", "the composer text is kept per thread")
    }

    // MARK: Stopping

    @Test func stopEndsTheTurnAndQuitStopsOneThatIsOpen() async throws {
        let id = first
        let gates = [Gate(), Gate()]
        let turn = Seen()
        let (store, _) = try await opened(chat: { _, _, _, _, stop in
            turn.add("t")
            let gate = gates[turn.all.count - 1]
            stop.attach { Task { await gate.open() } }
            await gate.wait()
            return ChatResult(id: id, reply: nil, end: "stopped", provider: .claude)
        })
        #expect(store.liveWork == nil)
        store.chatDraft = "hello"
        let sending = Task { await store.sendChat() }
        while !store.chatReplying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.liveWork == "a chat turn is still going.")
        await store.stopWorkAndWait()
        #expect(!store.chatReplying)
        #expect(await sending.value)
        #expect(store.actionError == "The turn was stopped.")
        #expect(store.liveWork == nil)

        store.chatDraft = "again"
        let again = Task { await store.sendChat() }
        while !store.chatReplying { try await Task.sleep(for: .milliseconds(10)) }
        store.stopChat()
        _ = await again.value
        #expect(!store.chatReplying)
    }

    // MARK: Making a goal

    @Test func aChatMadeIntoAGoalIsReadAgainAndOnlyOneDraftRunsAtATime() async throws {
        let gate = Gate()
        let seen = Seen()
        let id = first
        let (store, fixture) = try await opened(draftFromChat: { _, thread, _ in
            seen.add(thread)
            await gate.wait()
            return GoalDraftResult(id: thread, provider: .claude)
        })
        let making = Task { await store.makeChatGoal() }
        while !store.drafting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await store.makeChatGoal() == false, "one draft at a time")
        #expect(await store.sendChat() == false)
        try fixture.goalText(id: id, approved: false, title: "Retry uploads", proofs: nil, request: "Do it.")
            .write(to: fixture.project.goalURL(id), atomically: true, encoding: .utf8)
        try fixture.append(id, .goalSaved, data: ["status": "draft", "hash": .null])
        await gate.open()
        #expect(await making.value)
        #expect(seen.all == [id] && !store.drafting && store.actionError == nil)
        guard case .thread(let shown) = store.screen else { throw Failure.notAThread }
        #expect(shown.title == "Retry uploads" && shown.stateText == "Draft · not approved")
    }

    @Test func aDraftThatDoesNotComeOutLeavesTheChatAndSaysWhy() async throws {
        let (failed, _) = try await opened(draftFromChat: { _, _, _ in
            GoalDraftResult(id: nil, provider: .claude, costUSD: 0.5, failure: "the answer was not a goal")
        })
        #expect(await failed.makeChatGoal() == false)
        #expect(failed.actionError == "No draft ($0.5000 spent): the answer was not a goal. Nothing was written.")
        #expect(!failed.drafting)
        guard case .thread(let shown) = failed.screen else { throw Failure.notAThread }
        #expect(shown.state.isChat && shown.state.chat?.messages.count == 2, "the conversation is intact")

        let (refused, _) = try await opened(draftFromChat: { _, _, _ in throw GoalDraftRefusal.noGoalAgent })
        #expect(await refused.makeChatGoal() == false)
        #expect(refused.actionError == "\(GoalDraftRefusal.noGoalAgent)" && !refused.goalAgentOff)
        let (busy, _) = try await opened(draftFromChat: { _, _, _ in throw GoalDraftRefusal.busy })
        #expect(await busy.makeChatGoal() == false && busy.actionError == "\(GoalDraftRefusal.busy)")
    }

    @Test func aStoppedDraftSaysSoAndQuitStopsIt() async throws {
        let gate = Gate()
        let (store, _) = try await opened(draftFromChat: { _, _, stop in
            stop.attach { Task { await gate.open() } }
            await gate.wait()
            return GoalDraftResult(id: nil, provider: .claude, failure: "stopped")
        })
        let making = Task { await store.makeChatGoal() }
        while !store.drafting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.liveWork == "a goal draft is still going.")
        await store.stopWorkAndWait()
        #expect(await making.value == false)
        #expect(store.actionError == "Drafting was stopped. Nothing was written.")
    }

    @Test func doItNowIsTheAdvancedDraftFromTheWordsAndRunsNoChatTurn() async throws {
        let seen = Seen()
        let (store, _) = try await opened(
            chat: { _, _, _, _, _ in
                seen.add("chat")
                throw GoalActions.Unset()
            },
            draftGoal: { _, name, request, _, _ in
                seen.add("draft \(name)|\(request)")
                return GoalDraftResult(id: "g-\(name)", provider: .claude)
            })
        #expect(await store.doItNow("  Fix the header "))
        #expect(seen.all == ["draft fix-the-header|Fix the header"])
    }

    // MARK: The session

    @Test func aSessionWithAComposerDraftOrATurnOpenIsKept() {
        let session = ThreadSession(key: .init(project: nil, thread: "t"))
        #expect(session.isSpent)
        session.chatDraft = "half a thought"
        #expect(!session.isSpent && session.isIdle)
        session.chatDraft = ""
        session.replying = true
        #expect(!session.isIdle && !session.isSpent)
        session.replying = false
        #expect(session.isSpent)
    }

    // MARK: The live seams

    @Test func theLiveSeamsReachCoreWithTheProjectsConfig() async throws {
        let fixture = try await fixture()
        try addChat(fixture, first)
        // A config that is there but does not load is its own error, so the seams read it rather than assume none.
        try "[agents.goal\n".write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        let stop = DraftStop()
        for call in [
            { _ = try await GoalActions.core.chat(fixture.project, .existing(id: first), "hi", [], stop) },
            { _ = try await GoalActions.core.draftFromChat(fixture.project, first, stop) },
        ] as [() async throws -> Void] {
            do {
                try await call()
                Issue.record("a broken config did not stop the call")
            } catch {
                #expect(!(error is ChatRefusal) && !(error is GoalDraftRefusal), "\(error)")
            }
        }
        try FileManager.default.removeItem(at: fixture.project.configURL)
        await #expect(throws: ChatRefusal.noGoalAgent) {
            _ = try await GoalActions.core.chat(fixture.project, .existing(id: first), "hi", [], stop)
        }
        await #expect(throws: GoalDraftRefusal.noGoalAgent) {
            _ = try await GoalActions.core.draftFromChat(fixture.project, first, stop)
        }
    }

    private enum Failure: Error { case notAThread }
}

/// Screenshots sent with a chat message.
extension ProjectStoreChatTests {
    private func stagedPicture(_ store: ProjectStore) async throws -> URL {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chat-shot-\(UUID().uuidString).png")
        try png.write(to: file)
        await store.chatStaging.add(files: [file])
        return try #require(store.chatStaging.urls.first)
    }

    @Test func stagedScreenshotsGoWithTheMessageAndLeaveWhenItStarts() async throws {
        let seen = Seen()
        let id = first
        let (store, _) = try await opened(chat: { _, _, message, attachments, _ in
            seen.add("\(message)|\(attachments.map { FileManager.default.fileExists(atPath: $0.path) })")
            return ChatResult(id: id, reply: "Yes.", end: "ok", provider: .claude)
        })
        _ = try await stagedPicture(store)
        store.chatDraft = "what is this?"
        #expect(await store.sendChat())
        #expect(seen.all == ["what is this?|[true]"], "the file was there when core was asked")
        #expect(store.chatStaging.items.isEmpty, "and is cleared once the turn started")
    }

    @Test func refusalKeepsScreenshots() async throws {
        let (store, _) = try await opened(chat: { _, _, _, _, _ in throw ChatRefusal.tooManyImages })
        let staged = try await stagedPicture(store)
        store.chatDraft = "one more picture"
        #expect(await store.sendChat() == false)
        #expect(store.chatDraft == "one more picture", "the text came back")
        #expect(store.chatStaging.urls == [staged], "and so did the screenshot")
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(store.actionError == "\(ChatRefusal.tooManyImages)")
        store.chatStaging.clear()
    }

    @Test func aNewChatTakesTheScreenshotsToo() async throws {
        let seen = Seen()
        let id = first
        let (store, _) = try await opened(chat: { _, target, _, attachments, _ in
            seen.add("\(target)|\(attachments.count)")
            return ChatResult(id: id, reply: "Yes.", end: "ok", provider: .claude)
        }, chats: [])
        #expect(await store.startChat("Could uploads retry?", attachments: [URL(fileURLWithPath: "/tmp/a.png")]))
        #expect(seen.all.count == 1 && seen.all[0].hasSuffix("|1"), "\(seen.all)")
    }
}
