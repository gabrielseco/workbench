import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptFixtures: [AppFixture] = []

/// A decision or a chat reply in one thread holds that thread only: another thread's buttons and composer stay usable.
@MainActor @Suite struct PerThreadDecisionTests {
    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "never: \(what)")
    }

    private func open(_ actions: GoalActions) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        for name in ["t1", "t2"] {
            try await fixture.addThread(name, approved: true)
            try fixture.turn(name, 1)
        }
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    @Test func aDecisionInOneThreadDoesNotHoldAnother() async throws {
        let gate = Gate()
        let planned = Seen()
        let actions = GoalActions(acceptPlan: { _, thread in
            planned.add(thread)
            if thread == "t1" { await gate.wait() }
            throw PerThreadRefused()
        })
        let store = try await open(actions)
        await store.select(thread: "t1")
        let first = Task { await store.accept() }
        try await until("t1 is being decided") { store.deciding && planned.all == ["t1"] }
        await store.select(thread: "t2")
        #expect(!store.deciding, "t2 is not being decided")
        await store.accept()
        #expect(planned.all == ["t1", "t2"], "the decision in t2 ran beside the one in t1")
        gate.open()
        _ = await first.value
        await store.select(thread: "t1")
        #expect(!store.deciding)
    }

    @Test func aChatReplyInOneThreadDoesNotHoldAnotherThreadsChat() async throws {
        let gate = Gate()
        let sent = Seen()
        let actions = GoalActions(chat: { _, target, _, _, _ in
            sent.add("\(target)")
            if sent.all.count == 1 { await gate.wait() }
            return ChatResult(id: "t", reply: "Yes.", end: "ok", costUSD: 0.01, provider: .claude)
        })
        let store = try await open(actions)
        await store.select(thread: "t1")
        store.chatDraft = "one"
        let first = Task { await store.sendChat() }
        try await until("the first reply is going") { store.replyingHere }
        await store.select(thread: "t2")
        #expect(!store.replyingHere)
        store.chatDraft = "two"
        _ = await store.sendChat()
        #expect(sent.all.count == 2, "the second thread's message was sent while the first was answering")
        gate.open()
        _ = await first.value
    }
}

private struct PerThreadRefused: Error {}

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    nonisolated func open() { Task { await release() } }
    private func release() {
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
