import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptDraftFixtures: [AppFixture] = []

@MainActor @Suite struct DraftGoalTests {
    private typealias Draft = @Sendable (Project, String, String, DraftStop) async throws -> GoalDraftResult

    private func store(_ draft: @escaping Draft) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        keptDraftFixtures.append(fixture)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: GoalActions(draftGoal: draft))
        #expect(await store.open(fixture.root))
        return store
    }

    @Test func theNameComesFromTheFirstLineOfTheRequest() {
        let long = "Add retry with backoff to the sync client\nmore"
        #expect(ThreadName.suggest(from: long) == "add-retry-with-backoff-to-the-sync")
        #expect(ThreadName.suggest(from: "\n\n  Fix: the Settings screen's title!  ") == "fix-the-settings-screen-s-title")
        #expect(ThreadName.suggest(from: "¿¡?!") == "goal")
        #expect(ThreadName.suggest(from: String(repeating: "x", count: 100)).count == ThreadName.limit)
    }

    @Test func aSuggestedNameIsAlwaysAUsableThreadID() {
        for request in ["Añadir reintentos", "a/b\\c..d", "--flag", "  ", "日本語", "x y\tz"] {
            let name = ThreadName.suggest(from: request)
            #expect(name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil)
        }
    }

    @Test func theRequestGoesToTheDrafterTrimmedUnderTheSuggestedNameUnlessOneWasTyped() async throws {
        let seen = Seen()
        let store = try await store { _, name, request, _ in
            seen.add("\(name)|\(request)")
            return GoalDraftResult(id: "g-\(name)", provider: .claude)
        }
        #expect(await store.draftGoal(request: "  Fix the header\n\nand the footer \n"))
        #expect(await store.draftGoal(request: "Fix it", name: " header \n"))
        #expect(seen.all == ["fix-the-header|Fix the header\n\nand the footer", "header|Fix it"])
        #expect(!store.drafting && store.actionError == nil)
    }

    @Test func aDraftThatDoesNotComeOutSaysWhyAndSucceedsNot() async throws {
        let store = try await store { _, _, _, _ in
            GoalDraftResult(id: nil, provider: .claude, costUSD: 0.5, failure: "the answer was not a goal")
        }
        #expect(await store.draftGoal(request: "x") == false)
        #expect(store.actionError == "No draft ($0.5000 spent): the answer was not a goal. Nothing was written.")
        #expect(!store.drafting)
    }

    @Test func aRefusalFromCoreIsShown() async throws {
        let store = try await store { _, _, _, _ in throw GoalDraftRefusal.noGoalAgent }
        #expect(await store.draftGoal(request: "x") == false)
        #expect(store.actionError == "\(GoalDraftRefusal.noGoalAgent)")
    }

    @Test func stoppingWhileItDraftsSaysSoAndASecondDraftIsRefusedMeanwhile() async throws {
        let gate = Gate()
        let calls = Seen()
        let store = try await store { _, name, _, stop in
            calls.add(name)
            stop.attach { Task { await gate.open() } }
            await gate.wait()
            return GoalDraftResult(id: nil, provider: .claude, failure: "stopped")
        }
        let first = Task { await store.draftGoal(request: "one") }
        while !store.drafting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await store.draftGoal(request: "two") == false)
        store.stopDrafting()
        #expect(await first.value == false)
        #expect(calls.all == ["one"])
        #expect(store.actionError == "Drafting was stopped. Nothing was written.")
    }

    @Test func aStopAskedBeforeTheDrafterIsAttachedReachesItWhenItIs() {
        let stop = DraftStop()
        let stopped = Seen()
        stop.stop()
        #expect(stop.wasRequested)
        stop.attach { stopped.add("stopped") }
        #expect(stopped.all == ["stopped"])
    }

    @Test func aStopAskedAfterTheDrafterIsAttachedEndsItOnce() {
        let stop = DraftStop()
        let stopped = Seen()
        stop.attach { stopped.add("stopped") }
        #expect(stopped.all.isEmpty)
        stop.stop()
        #expect(stopped.all == ["stopped"])
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

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
