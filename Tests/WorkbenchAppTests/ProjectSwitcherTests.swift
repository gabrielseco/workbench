import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct ProjectSwitcherTests {
    private func project(_ thread: String = "t1", approved: Bool = true) async throws -> AppFixture {
        let fixture = try await AppFixture()
        try await fixture.addThread(thread, approved: approved)
        keptFixtures.append(fixture)
        return fixture
    }

    private func store(_ prefs: MemoryPreferences = MemoryPreferences(), actions: GoalActions = GoalActions()) -> ProjectStore {
        ProjectStore(preferences: prefs, intervals: (.milliseconds(20), .milliseconds(20)), actions: actions)
    }

    @Test func openingAProjectPutsItFirstOnceAndTheMenuTicksTheCurrentOne() async throws {
        let (a, b) = (try await project("a"), try await project("b"))
        let store = store()
        let opened = [await store.open(a.root), await store.open(b.root), await store.open(a.root)]
        #expect(opened == [true, true, true])
        let list = store.recentProjects()
        #expect(list.map(\.path) == [a.project.root.path, b.project.root.path])
        #expect(list.map(\.isCurrent) == [true, false])
    }

    @Test func theListKeepsTheNewestTenAndSurvivesARelaunch() async throws {
        let prefs = MemoryPreferences()
        let store = store(prefs)
        for index in 0..<12 { store.remember("/tmp/p\(index)") }
        #expect(store.recentPaths.count == 10 && store.recentPaths.first == "/tmp/p11" && !store.recentPaths.contains("/tmp/p0"))
        #expect(self.store(prefs).recentPaths == store.recentPaths)
    }

    @Test func theOldSingleRememberedPathIsNotLostOnUpgrade() {
        let prefs = MemoryPreferences(projectPath: "/tmp/old")
        #expect(store(prefs).recentPaths == ["/tmp/old"])
        let both = MemoryPreferences(projectPath: "/tmp/old", recentProjects: ["/tmp/new", "/tmp/old"])
        #expect(store(both).recentPaths == ["/tmp/new", "/tmp/old"])
    }

    @Test func twoFoldersWithTheSameNameAreToldApartByTheirParent() {
        let store = store()
        store.remember("/tmp/one/app")
        store.remember("/tmp/two/app")
        store.remember("/tmp/solo")
        #expect(store.recentProjects().map(\.name) == ["solo", "app (two)", "app (one)"])
    }

    @Test func aGoneFolderOrANonRepositoryIsUnavailableAndRefusedWithoutClosingTheOpenProject() async throws {
        let a = try await project("a")
        let store = store()
        #expect(await store.open(a.root))
        let notRepo = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notRepo) }
        store.remember(notRepo.path)
        store.remember("/tmp/definitely-gone-\(UUID().uuidString)")
        let reasons = store.recentProjects().compactMap(\.unavailable)
        #expect(reasons == ["The folder is gone.", "It is no longer a git repository."])
        await store.switchTo(notRepo.path)
        #expect(store.project == a.project && store.actionError?.hasSuffix("It is no longer a git repository.") == true)
        guard case .thread = store.screen else {
            Issue.record("the open project was closed")
            return
        }
    }

    @Test func anUnavailableProjectCanBeRemovedFromTheList() {
        let store = store()
        store.remember("/tmp/gone-for-good")
        store.forget("/tmp/gone-for-good")
        #expect(store.recentPaths.isEmpty)
    }

    @Test func switchingShowsTheOtherProjectsThreadAndDropsTheFirstsConfirmations() async throws {
        let (a, b) = (try await project("first"), try await project("second"))
        let shown = AcceptPlan(
            id: "first", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/first", diff: .unavailable(reason: "x"),
            hasPendingChanges: false, commits: [], check: nil, openWork: false, snapshot: "s", defaultMessage: "m")
        try a.turn("first", 1)
        let store = store(actions: GoalActions(acceptPlan: { _, _ in shown }))
        #expect(await store.open(a.root))
        await store.prepareAccept()
        #expect(store.pendingAccept != nil)
        await store.switchTo(b.project.root.path)
        guard case .thread(let now) = store.screen else {
            Issue.record("no thread")
            return
        }
        #expect(now.id == "second" && store.pendingAccept == nil && store.review == nil && store.project == b.project)
    }

    @Test func aRunStartedInOneProjectKeepsGoingWhenYouSwitchAndIsMarkedRunning() async throws {
        let (a, b) = (try await project("a"), try await project("b"))
        let gate = Gate()
        let stopped = Flag()
        let actions = GoalActions(makeRun: { _, _, _ in
            RunHandle(run: { await gate.wait() }, stop: { stopped.set() })
        })
        let store = store(actions: actions)
        try a.turn("a", 1, result: "interrupted")
        #expect(await store.open(a.root))
        await store.runAgain()
        #expect(store.recentProjects().first { $0.isCurrent }?.isRunning == true)
        await store.switchTo(b.project.root.path)
        let list = store.recentProjects()
        #expect(list.first { $0.path == a.project.root.path }?.isRunning == true)
        #expect(list.first { $0.isCurrent }?.isRunning == false && !stopped.value)
        #expect(!store.runningHere, "the run is not b's")
        await store.switchTo(a.project.root.path)
        #expect(store.runningHere)
        await gate.open()
    }
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
