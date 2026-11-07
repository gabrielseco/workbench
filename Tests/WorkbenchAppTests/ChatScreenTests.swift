import Foundation
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptChatScreenFixtures: [AppFixture] = []

/// The chat screen (P22 slice 6c-2): what its composer allows, which threads get it, and the way in on the New goal card.
@MainActor @Suite struct ChatScreenTests {
    private func snapshot(_ scenario: AppScenario) async throws -> ThreadSnapshot {
        let fixture = try await AppFixture()
        keptChatScreenFixtures.append(fixture)
        try await scenario.build(in: fixture)
        guard case .thread(let shown) = ProjectLoader.load(project: fixture.project).screen else {
            throw Failure.notAThread
        }
        return shown
    }

    private func state(
        _ snapshot: ThreadSnapshot, text: String = "hi", replying: Bool = false, drafting: Bool = false
    ) -> ChatComposerState {
        ChatComposerState(snapshot: snapshot, replying: replying, drafting: drafting, text: text)
    }

    // MARK: Which threads show the chat

    @Test func aChatShowsTheChatScreenAndAChatThatBecameAGoalDoesNot() async throws {
        let chat = try await snapshot(.chat)
        #expect(chat.showsChat && chat.state.chat?.messages.count == 2)
        #expect(try await snapshot(.chatGoal).showsChat == false)
        #expect(try await snapshot(.draft).showsChat == false)
        #expect(try await snapshot(.needsYou).showsChat == false)
    }

    // MARK: The composer

    @Test func sendWaitsForAScreenshotStillBeingRead() async throws {
        let chat = try await snapshot(.chat)
        #expect(state(chat).canSend)
        #expect(ChatComposerState(snapshot: chat, replying: false, drafting: false, text: "hi", pending: 1).canSend == false)
    }

    @Test func aMessageWithScreenshotsSaysSoToVoiceOver() {
        let plain = ChatMessage(role: .user, text: "hello", seq: 1)
        let shown = ChatMessage(role: .user, text: "hello", seq: 2, images: ["1.png", "2.png"])
        #expect(plain.spoken == "You: hello" && shown.spoken == "You: hello (with 2 screenshot(s))")
    }

    @Test func sendNeedsTextAndNoTurnAndNoDraft() async throws {
        let chat = try await snapshot(.chat)
        #expect(state(chat).canSend)
        #expect(!state(chat, text: "").canSend && !state(chat, text: " \n\t ").canSend)
        #expect(!state(chat, replying: true).canSend && !state(chat, drafting: true).canSend)
        #expect(state(chat).canType)
        #expect(!state(chat, replying: true).canType && !state(chat, drafting: true).canType, "no typing mid-turn")
    }

    @Test func aTurnTheLogShowsOpenCountsAsReplyingEvenWhenThisAppHoldsNone() async throws {
        let open = try await snapshot(.chatReplying)
        let composer = state(open)
        #expect(composer.replying && !composer.canSend && !composer.canMakeGoal)
        #expect(state(try await snapshot(.chat)).replying == false)
    }

    @Test func makeThisAGoalNeedsAFinishedExchangeAndNothingGoing() async throws {
        let chat = try await snapshot(.chat)
        #expect(state(chat).canMakeGoal && state(chat, text: "").canMakeGoal, "the text box does not matter")
        #expect(!state(chat, replying: true).canMakeGoal && !state(chat, drafting: true).canMakeGoal)
        var unanswered = chat
        let asked = unanswered.state.chat?.messages.filter { $0.role == .user } ?? []
        unanswered.state.chat?.messages = asked
        #expect(!state(unanswered).canMakeGoal, "nothing to make a goal from before the agent has answered")
    }

    @Test func anEndedChatTakesNothingMore() async throws {
        var chat = try await snapshot(.chat)
        chat.state.decision = "abandoned"
        let composer = state(chat)
        #expect(composer.ended && !composer.canSend && !composer.canMakeGoal && !composer.canType)
    }

    @Test func returnSendsAndShiftOrOptionReturnAddsALine() {
        #expect(ChatComposerState.key(shift: false, option: false) == .send)
        #expect(ChatComposerState.key(shift: true, option: false) == .newline)
        #expect(ChatComposerState.key(shift: false, option: true) == .newline)
    }

    // MARK: The way in

    @Test func aChatStartsAChatAndNoDraft() async throws {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var calls: [String] = []
            func add(_ call: String) { lock.withLock { calls.append(call) } }
        }
        let seen = Seen()
        let fixture = try await AppFixture()
        keptChatScreenFixtures.append(fixture)
        let actions = GoalActions(
            draftGoal: { _, name, _, _, _ in
                seen.add("draft \(name)")
                return GoalDraftResult(id: "g-\(name)", provider: .claude)
            },
            chat: { _, target, message, _, _ in
                seen.add("chat \(target)|\(message)")
                return ChatResult(id: "g-2026-11-03-x", reply: "ok", end: "ok", provider: .claude)
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        #expect(await store.startChat("Could uploads retry?"))
        #expect(seen.calls == ["chat newThread(name: \"could-uploads-retry\")|Could uploads retry?"])
    }

    // MARK: What is drawn

    private func window(_ snapshot: ThreadSnapshot, store base: ProjectStore) throws -> CGImage {
        let preferences = MemoryPreferences()
        let store = ProjectStore(preferences: preferences, screen: .thread(snapshot), project: base.project)
        let view = RootView(store: store).frame(width: 1100, height: 700)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.feedDrawsEagerly, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    /// `ImageRenderer` cannot read text back, so this proves the pieces are drawn by taking each one away and seeing the window change.
    @Test func theConversationAndTheComposerAreDrawnInTheWindow() async throws {
        let chat = try await snapshot(.chat)
        let fixture = try await AppFixture()
        keptChatScreenFixtures.append(fixture)
        let store = ProjectStore(preferences: MemoryPreferences(), project: fixture.project)
        let whole = try window(chat, store: store)
        var silent = chat
        silent.state.chat?.messages = []
        var ended = chat
        ended.state.decision = "abandoned"
        for (what, other) in [("the messages", silent), ("the composer", ended)] {
            let without = try window(other, store: store)
            #expect(whole.dataProvider?.data != without.dataProvider?.data, "\(what) are not drawn")
        }
    }

    private func drawn(_ view: some View, height: CGFloat = 400) throws -> Data? {
        let framed = view.frame(width: 700, height: height).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        return try #require(renderer.cgImage).dataProvider?.data as Data?
    }

    /// Each part on its own, so a part that goes missing is not hidden by another one that is still there.
    @Test func eachPartOfTheChatIsDrawnOnItsOwn() async throws {
        let chat = try await snapshot(.chat)
        let fixture = try await AppFixture()
        keptChatScreenFixtures.append(fixture)
        let store = ProjectStore(preferences: MemoryPreferences(), project: fixture.project)
        var other = chat
        let count = other.state.chat?.messages.count ?? 0
        for index in 0..<count { other.state.chat?.messages[index].text = "Different words entirely." }
        let wording = try (drawn(ChatRows(snapshot: chat, store: store)), drawn(ChatRows(snapshot: other, store: store)))
        #expect(wording.0 != wording.1, "the messages")
        var unanswered = chat
        let asked = unanswered.state.chat?.messages.filter { $0.role == .user } ?? []
        unanswered.state.chat?.messages = asked
        let whole = try drawn(ChatComposer(snapshot: chat, store: store), height: 200)
        #expect(whole != (try drawn(ChatComposer(snapshot: unanswered, store: store), height: 200)), "the buttons")
        var ended = chat
        ended.state.decision = "abandoned"
        #expect(whole != (try drawn(ChatComposer(snapshot: ended, store: store), height: 200)), "the composer")
    }

    @Test func theBubblesAndTheAvatarCarryNoLabelSoVoiceOverSaysWhoSpoke() async throws {
        let chat = try await snapshot(.chat)
        let spoken = (chat.state.chat?.messages ?? []).map(\.spoken)
        #expect(spoken == ["You: Could uploads retry with backoff?", "Goal agent: What should happen after the fifth try?"])
    }

    /// The button on its own, so it cannot be hidden by the text box changing: drawn, dimmed when there is nothing to send, and not
    /// the same as nothing at all.
    @Test func theSendButtonIsDrawnAndDimmedOnItsOwn() throws {
        let on = try drawn(ComposerSendButton(enabled: true) {}, height: 60)
        let off = try drawn(ComposerSendButton(enabled: false) {}, height: 60)
        let nothing = try drawn(Color.clear, height: 60)
        #expect(on != off, "dimmed without text")
        #expect(on != nothing && off != nothing, "drawn either way")
    }

    @Test func theColumnAndTheBubblesAreTheArtboardsWidths() {
        #expect(FeedLayout.maxColumn == 680 && FeedLayout.agentText == 620 && FeedLayout.userBubble == 540)
    }

    @Test func aDamagedLogIsSaidOnTheChatScreen() async throws {
        let chat = try await snapshot(.chat)
        let fixture = try await AppFixture()
        keptChatScreenFixtures.append(fixture)
        let store = ProjectStore(preferences: MemoryPreferences(), project: fixture.project)
        var damaged = chat
        damaged.feed = [FeedItem(id: "damage", seq: 0, turn: 0, kind: .notice(.logTailCut))]
        #expect(damaged.feed.allSatisfy { $0.isNotice })
        let (said, plain) = try (drawn(ChatRows(snapshot: damaged, store: store)), drawn(ChatRows(snapshot: chat, store: store)))
        #expect(said != plain)
    }

    private enum Failure: Error { case notAThread }
}

/// The composer's text box shows no scroll bar (a grey pill beside the Send button on a Mac that shows scroll bars): what is done to its
/// scroll view, which is all a test can see of it.
@MainActor @Suite struct TextScrollerHiderTests {
    @Test func aScrollViewIsGivenAScrollerThatDrawsNothingAndItStaysThatWay() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        scroll.documentView = NSTextView(frame: scroll.bounds)
        scroll.hasVerticalScroller = true
        TextScrollerHider.blank(scroll)
        #expect(scroll.verticalScroller is BlankScroller)
        #expect(scroll.verticalScroller?.alphaValue == 0 && scroll.verticalScroller?.isHidden == true)
        #expect(!scroll.hasHorizontalScroller)
        let first = scroll.verticalScroller
        TextScrollerHider.blank(scroll)
        #expect(scroll.verticalScroller === first, "repeating it keeps the same scroller")
        #expect(BlankScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) == 0, "it takes no room")
    }
}
