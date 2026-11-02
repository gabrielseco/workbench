import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptSessionFixtures: [AppFixture] = []

/// What the window holds for a thread (its error, note, notice, goal) is the thread's: another thread never shows it.
@MainActor @Suite struct ThreadSessionTests {
    private func opened() async throws -> (ProjectStore, AppFixture) {
        let fixture = try await AppFixture()
        keptSessionFixtures.append(fixture)
        try await fixture.addThread("t1")
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil))
        #expect(await store.open(fixture.root))
        return (store, fixture)
    }

    @Test func whatOneThreadSaidIsNotShownOnAnotherInTheSameProject() async throws {
        let (store, fixture) = try await opened()
        #expect(store.currentThread == "t1" && store.goal != nil)
        (store.actionError, store.actionNote, store.notice) = ("broke", "left out", "Accepted")
        store.goalEditError = "refused"

        try await fixture.addThread("t2")
        await store.reload()
        #expect(store.currentThread == "t2")
        #expect(store.actionError == nil && store.actionNote == nil && store.notice == nil && store.goalEditError == nil)
        #expect(store.goal != nil, "the new thread's own goal is read")
    }

    @Test func whatOneProjectSaidIsNotShownOnAnother() async throws {
        let (store, _) = try await opened()
        let other = try await AppFixture()
        keptSessionFixtures.append(other)
        try await other.addThread("o1")
        store.actionError = "broke"
        store.pendingDiscard = nil

        await store.switchTo(other.project.root.path)
        #expect(store.actionError == nil && store.currentThread == "o1")
    }

    @Test func theSessionOfTheThreadOnScreenSurvivesAReloadOfTheSameThread() async throws {
        let (store, _) = try await opened()
        let session = store.current
        store.actionError = "broke"
        await store.reload()
        #expect(store.current === session && store.actionError == "broke")
    }
}
