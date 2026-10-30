import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptEditFixtures: [AppFixture] = []

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var edits: [(String, GoalEdit)] = []
    func add(_ thread: String, _ edit: GoalEdit) { lock.withLock { edits.append((thread, edit)) } }
    var all: [(String, GoalEdit)] { lock.withLock { edits } }
}

private actor EditGate {
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

/// The store hands an edit to core's `editGoal` for the thread on screen, says why a refusal was one, and reads the file again.
@MainActor @Suite struct GoalEditStoreTests {
    private func store(_ actions: GoalActions) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        keptEditFixtures.append(fixture)
        try await fixture.addThread("t1", approved: false)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    @Test func anEditGoesToCoreForTheThreadOnScreenAndNothingIsSaidWhenItWorks() async throws {
        let seen = Seen()
        let store = try await store(GoalActions(editGoal: { _, thread, edit in seen.add(thread, edit) }))
        await store.editGoal(.setSkip(["judge"]))
        #expect(seen.all.map(\.0) == ["t1"] && seen.all.map(\.1) == [.setSkip(["judge"])])
        #expect(store.goalEditError == nil)
    }

    @Test func aRefusalIsSaidInCoresWordsAndClearedByTheNextEditThatWorks() async throws {
        let refuse = Seen()
        let store = try await store(
            GoalActions(editGoal: { _, thread, edit in
                refuse.add(thread, edit)
                if case .setTitle = edit { throw GoalActions.RefusalText("the goal was not changed: the title cannot be empty") }
            }))
        await store.editGoal(.setTitle(""))
        #expect(store.goalEditError == "the goal was not changed: the title cannot be empty")
        await store.editGoal(.setSkip([]))
        #expect(store.goalEditError == nil)
    }

    @Test func theGoalIsReadAgainAfterAnEdit() async throws {
        let fixture = try await AppFixture()
        keptEditFixtures.append(fixture)
        try await fixture.addThread("t1", approved: false)
        let url = fixture.project.goalURL("t1")
        let actions = GoalActions(editGoal: { _, _, _ in
            let text = try String(contentsOf: url, encoding: .utf8)
            try text.replacingOccurrences(of: "Do the thing.", with: "Changed.").write(to: url, atomically: true, encoding: .utf8)
        })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        let before = store.goal?.request
        await store.editGoal(.setRequest("Changed."))
        #expect(store.goal?.request != before)
    }

    @Test func twoQuickEditsEachBuildOnTheOthersResultAndNoneIsLost() async throws {
        let fixture = try await AppFixture()
        keptEditFixtures.append(fixture)
        try await fixture.addThread("t1", approved: false)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: .core)
        #expect(await store.open(fixture.root))
        let before = try #require(store.goal).outOfScope
        // Both are made from the displayed goal, before either has been written: the second must not undo the first.
        async let first: Void = store.editGoal { .setOutOfScope($0.outOfScope + ["First."]) }
        async let second: Void = store.editGoal { .setOutOfScope($0.outOfScope + ["Second."]) }
        _ = await (first, second)
        #expect(try #require(store.goal).outOfScope == before + ["First.", "Second."])
        #expect(store.goalEditError == nil)
    }

    @Test func anEditThatNoLongerMakesSenseIsDroppedNotWritten() async throws {
        let seen = Seen()
        let store = try await store(GoalActions(editGoal: { _, thread, edit in seen.add(thread, edit) }))
        await store.editGoal { _ in nil }
        #expect(seen.all.isEmpty)
    }

    @Test func everyEditThatEndsCountsSoARefusedFieldCanShowWhatTheFileHas() async throws {
        let store = try await store(
            GoalActions(editGoal: { _, _, edit in
                if case .setTitle = edit { throw GoalActions.RefusalText("no") }
            }))
        let start = store.goalEditSerial
        await store.editGoal(.setTitle(""))
        await store.editGoal(.setSkip([]))
        #expect(store.goalEditSerial == start + 2, "a refusal counts too")
    }

    @Test func anEditQueuedForAnotherProjectIsDroppedWhenTheWindowHasMoved() async throws {
        let first = try await AppFixture(), second = try await AppFixture()
        keptEditFixtures += [first, second]
        try await first.addThread("t1", approved: false)
        try await second.addThread("t1", approved: false)
        let seen = Seen()
        let store = ProjectStore(
            preferences: MemoryPreferences(projectPath: nil), actions: GoalActions(editGoal: { project, thread, edit in
                seen.add("\(project.root.lastPathComponent)/\(thread)", edit)
            }))
        #expect(await store.open(first.root))
        async let queued: Void = store.editGoal(.setTitle("For the first project."))
        // The window moves before the queued edit's turn comes.
        _ = await store.open(second.root)
        await queued
        #expect(seen.all.allSatisfy { !$0.0.hasPrefix(second.project.root.lastPathComponent) }, "\(seen.all.map(\.0))")
    }

    @Test func approvalWaitsForTheEditsAlreadyMade() async throws {
        let order = Seen()
        let gate = EditGate()
        let actions = GoalActions(
            approve: { _, _ in order.add("approve", .setSkip([])) },
            editGoal: { _, _, edit in
                await gate.wait()
                order.add("edit", edit)
            })
        let store = try await store(actions)
        let editing = Task { await store.editGoal(.setSkip(["judge"])) }
        try await Task.sleep(for: .milliseconds(50))
        let approving = Task { await store.approveAndRun() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.all.isEmpty, "the approval did not go ahead of the edit")
        await gate.open()
        await editing.value
        await approving.value
        #expect(order.all.map(\.0) == ["edit", "approve"])
    }
}
