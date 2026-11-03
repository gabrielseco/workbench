import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptChatFixtures: [AppFixture] = []

/// A chat thread (P22 slice 6a) has no goal file: the window must show it as what it is instead of breaking. The chat screen is 6c.
@MainActor @Suite struct ChatThreadTests {
    private func chatFixture() async throws -> AppFixture {
        let fixture = try await AppFixture()
        keptChatFixtures.append(fixture)
        let id = "g-2026-11-03-idea"
        try FileManager.default.createDirectory(at: fixture.project.threadDirectory(id), withIntermediateDirectories: true)
        try fixture.append(id, .threadCreated, data: ["kind": "chat", "repo": .string(fixture.project.root.path)])
        try fixture.append(id, .chatMessage, data: ["role": "user", "text": "could uploads retry with backoff?\nand give up"])
        try fixture.append(id, .chatMessage, data: ["role": "assistant", "text": "What after five tries?"])
        try fixture.append(id, .chatEnded, data: ["ok": true, "cost_usd": 0.01])
        return fixture
    }

    @Test func theListShowsAChatByItsFirstWordsAndSaysChat() async throws {
        let fixture = try await chatFixture()
        let listing = ThreadListLoader.load(project: fixture.project, cache: .init())
        let row = try #require(listing.rows.first)
        #expect(row.title == "could uploads retry with backoff?" && row.line == "Chat" && row.mark == .idle)
    }

    @Test func aChatThatIsReplyingIsWorkingAndAnAbandonedOneIsOver() async throws {
        let fixture = try await chatFixture()
        let id = "g-2026-11-03-idea"
        try fixture.append(id, .chatMessage, data: ["role": "user", "text": "and then?"])
        var row = try #require(ThreadListLoader.load(project: fixture.project, cache: .init()).rows.first)
        #expect(row.mark == .working && row.line == "Chat · replying")
        try fixture.append(id, .chatEnded, data: ["ok": false, "reason": "interrupted", "synthetic": true])
        try fixture.decide(id, "abandoned")
        row = try #require(ThreadListLoader.load(project: fixture.project, cache: .init()).rows.first)
        #expect(row.line == "Abandoned" && row.mark == .idle)
    }

    @Test func theWindowOpensAChatThreadWithoutAGoalAndDoesNotBreak() async throws {
        let fixture = try await chatFixture()
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(fixture.root))
        guard case .thread(let shown) = store.screen else {
            Issue.record("a chat thread is not shown as a thread: \(store.screen)")
            return
        }
        #expect(shown.id == "g-2026-11-03-idea" && shown.state.isChat && shown.state.chat?.turns == 1)
        #expect(shown.title == "could uploads retry with backoff?" && shown.stateText == "Chat")
        let decision = FeedActions.derive(FeedActionContext(snapshot: shown))
        #expect(decision.primary == nil && decision.more.isEmpty, "a chat has nothing to approve or run")
        #expect(decision.title == "Chat")
        let withFeed = ProjectStore(preferences: { let p = MemoryPreferences(); p.chatFeed = true; return p }())
        #expect(await withFeed.open(fixture.root))
        if case .thread = withFeed.screen {} else { Issue.record("the feed does not show a chat thread: \(withFeed.screen)") }
    }
}
