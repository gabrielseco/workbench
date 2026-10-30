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
}
