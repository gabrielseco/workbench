import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptFixtures: [AppFixture] = []

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

/// P26 slice 2: the project rail's list, how it is seeded and kept, and what the open project's tile shows.
@MainActor @Suite struct ProjectRailStoreTests {
    private func fixture() async throws -> AppFixture {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        return fixture
    }

    @Test func aRailNeverArrangedStartsFromTheRecentsOldestFirst() async throws {
        let preferences = MemoryPreferences(projectPath: nil, recentProjects: ["/c", "/b", "/a"])
        let store = ProjectStore(preferences: preferences)
        #expect(store.railPaths == ["/a", "/b", "/c"])
        #expect(preferences.railProjects == nil, "seeding writes nothing: the rail is not arranged until the person does")
    }

    @Test func anArrangedRailIsKeptEvenWhenItIsEmpty() async throws {
        let preferences = MemoryPreferences(projectPath: nil, recentProjects: ["/a"])
        preferences.railProjects = []
        #expect(ProjectStore(preferences: preferences).railPaths.isEmpty, "removing every tile is not undone by the recents")
        preferences.railProjects = ["/z", "/y"]
        #expect(ProjectStore(preferences: preferences).railPaths == ["/z", "/y"])
    }

    @Test func aProjectThatIsOpenedIsPinnedOnceAtTheEndAndRemembered() async throws {
        let first = try await fixture()
        let second = try await fixture()
        let preferences = MemoryPreferences(projectPath: nil)
        let store = ProjectStore(preferences: preferences)
        #expect(await store.open(first.root))
        #expect(await store.open(second.root))
        #expect(await store.open(first.root))
        let (a, b) = (first.project.root.path, second.project.root.path)
        #expect(store.railPaths == [a, b], "each once, in the order first opened; reopening does not move a tile")
        #expect(preferences.railProjects == [a, b])
    }

    @Test func aTileForAFolderThatIsGoneSaysSoAndKeepsItsPlace() async throws {
        let preferences = MemoryPreferences(projectPath: nil)
        preferences.railProjects = ["/no/such/project"]
        let tiles = ProjectStore(preferences: preferences).railTiles()
        #expect(tiles.map(\.name) == ["project"] && tiles.first?.unavailable == "The folder is gone.")
    }

    @Test func removingATileOnlyHidesItAndLeavesTheRecents() async throws {
        let first = try await fixture()
        let second = try await fixture()
        let preferences = MemoryPreferences(projectPath: nil)
        let store = ProjectStore(preferences: preferences)
        #expect(await store.open(first.root))
        #expect(await store.open(second.root))
        let (a, b) = (first.project.root.path, second.project.root.path)

        await store.removeFromRail(a)
        #expect(store.railPaths == [b] && preferences.railProjects == [b])
        #expect(Set(store.recentPaths) == [a, b], "the project is still in the recents")
        #expect(store.project?.root.path == b, "a tile that is not the open one leaves the window where it was")
    }

    @Test func removingTheOpenTilesMovesToItsNeighbourOrStaysWhenAlone() async throws {
        let first = try await fixture()
        let second = try await fixture()
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil))
        #expect(await store.open(first.root))
        #expect(await store.open(second.root))
        let (a, b) = (first.project.root.path, second.project.root.path)

        await store.removeFromRail(b)
        #expect(store.project?.root.path == a && store.railPaths == [a], "the window follows to the neighbour")
        await store.removeFromRail(a)
        #expect(store.project?.root.path == a && store.railPaths.isEmpty, "with no other tile the project stays open")
    }

    @Test func aRunInAProjectTakenOffTheRailGoesOn() async throws {
        let running = try await fixture()
        try await running.addThread("t1", approved: true)
        try running.turn("t1", 1, result: "interrupted")
        let other = try await fixture()
        let gate = Gate()
        let actions = GoalActions(makeRun: { _, _, _ in RunHandle(run: { await gate.wait() }, stop: { await gate.open() }) })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(running.root))
        await store.runAgain()
        #expect(store.ownedRuns.count == 1)
        #expect(await store.open(other.root))

        await store.removeFromRail(running.project.root.path)
        #expect(store.ownedRuns.count == 1, "taking the tile away stops nothing")
        await store.stopWorkAndWait()
    }

    @Test func movingATileIsRememberedAndNeverLosesOne() async throws {
        let preferences = MemoryPreferences(projectPath: nil)
        preferences.railProjects = ["/a", "/b", "/c"]
        let store = ProjectStore(preferences: preferences)
        store.moveOnRail("/c", by: -1)
        #expect(store.railPaths == ["/a", "/c", "/b"] && preferences.railProjects == ["/a", "/c", "/b"])
        store.moveOnRail("/a", by: -1)
        #expect(store.railPaths == ["/a", "/c", "/b"], "the first tile cannot go earlier")
    }

    @Test func theOpenProjectsTileCountsWhatTheWindowReadsOfIt() async throws {
        let open = try await fixture()
        try await open.addThread("t1", approved: true)
        try open.turn("t1", 1)  // a turn ended with no decision: needs you
        let other = try await fixture()
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil))
        #expect(await store.open(open.root))
        await store.reload()

        #expect(store.railBadge(for: open.project.root.path) == .needsYou(1))
        #expect(store.railBadge(for: other.project.root.path) == .none, "another project has none until its summary is read")
    }
}
