import Foundation
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
        guard case .thread(let shown) = ProjectLoader.load(project: fixture.project, feed: true).screen else {
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

    @Test func sendNeedsTextAndNoTurnAndNoDraft() async throws {
        let chat = try await snapshot(.chat)
        #expect(state(chat).canSend)
        #expect(!state(chat, text: "").canSend && !state(chat, text: " \n\t ").canSend)
        #expect(!state(chat, replying: true).canSend && !state(chat, drafting: true).canSend)
        #expect(state(chat).canType)
        #expect(!state(chat, replying: true).canType && !state(chat, drafting: true).canType, "no typing while something is going")
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

    @Test func theTextBoxGrowsALineAtATimeAndStopsAtSix() {
        #expect(ChatComposerState.editorHeight(for: "") == 30 && ChatComposerState.editorHeight(for: "one line") == 30)
        #expect(ChatComposerState.editorHeight(for: "a\nb") == 50)
        #expect(ChatComposerState.editorHeight(for: String(repeating: "x\n", count: 40)) == 130)
    }

    // MARK: The way in

    @Test func theCardOffersChatOnlyWithThePreviewOn() {
        #expect(NewGoalForm.Mode.offered(chatFeed: false) == [.quick, .advanced])
        #expect(NewGoalForm.Mode.offered(chatFeed: true) == [.quick, .advanced, .chat])
        var form = NewGoalForm()
        form.mode = .chat
        #expect(form.action == "Send" && form.busyText == "Waiting for the reply…")
        #expect(form.note.contains("nothing is written to the repository"))
        form.mode = .quick
        #expect(form.action == "Create")
    }

    @Test func theChatKindStartsAChatAndNoDraft() async throws {
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
            chat: { _, target, message, _ in
                seen.add("chat \(target)|\(message)")
                return ChatResult(id: "g-2026-11-03-x", reply: "ok", end: "ok", provider: .claude)
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        var form = NewGoalForm()
        form.mode = .chat
        form.request = "Could uploads retry?"
        #expect(await store.createGoal(form))
        #expect(seen.calls == ["chat newThread(name: \"could-uploads-retry\")|Could uploads retry?"])
    }

    private enum Failure: Error { case notAThread }
}
