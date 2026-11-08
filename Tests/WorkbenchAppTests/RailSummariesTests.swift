import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptFixtures: [AppFixture] = []

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Polls `condition` until it holds or `timeout` passes.
private func waitUntil(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// P26 slice 3: what the rail's tiles count for the projects that are not open.
@MainActor @Suite struct RailSummariesTests {
    private func fixture(needsYou: Int = 0, running: Bool = false) async throws -> AppFixture {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        for index in 0..<needsYou {
            try await fixture.addThread("n\(index)", approved: true)
            try fixture.turn("n\(index)", 1)
        }
        if running {
            try await fixture.addThread("run", approved: true)
            try fixture.append("run", .turnStarted, turn: 1, data: ["session_id": "s1"])
        }
        return fixture
    }

    /// A store showing `open`, with `others` on its rail after it.
    private func store(open: AppFixture, others: [AppFixture]) async -> ProjectStore {
        let preferences = MemoryPreferences(projectPath: nil)
        preferences.railProjects = ([open] + others).map(\.project.root.path)
        let store = ProjectStore(preferences: preferences)
        _ = await store.open(open.root)
        return store
    }

    @Test func anotherProjectsTileCountsWhatItsLogsSay() async throws {
        let open = try await fixture()
        let busy = try await fixture(needsYou: 2, running: true)
        let quiet = try await fixture()
        let store = await store(open: open, others: [busy, quiet])

        await store.readRailSummaries()
        #expect(store.railBadge(for: busy.project.root.path) == .needsYou(2), "needs you beats running")
        #expect(store.railBadge(for: quiet.project.root.path) == .none)
    }

    @Test func aProjectWithOnlyARunningThreadShowsTheBlueDot() async throws {
        let open = try await fixture()
        let running = try await fixture(running: true)
        let store = await store(open: open, others: [running])
        await store.readRailSummaries()
        #expect(store.railBadge(for: running.project.root.path) == .running)
    }

    @Test func aLogThatCannotBeReadIsRedNotZero() async throws {
        let open = try await fixture()
        let broken = try await fixture()
        let url = broken.project.eventsURL("g-2026-11-08-bad")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not an event\nnot one either\n".write(to: url, atomically: true, encoding: .utf8)
        let store = await store(open: open, others: [broken])
        await store.readRailSummaries()
        #expect(store.railBadge(for: broken.project.root.path) == .failed(1), "a damaged log is failed")
    }

    @Test func theOpenProjectsTileIsTheWindowsOwnReadingAndNotThePoll() async throws {
        let open = try await fixture(needsYou: 1)
        let store = await store(open: open, others: [])
        await store.reload()
        #expect(store.railBadge(for: open.project.root.path) == .needsYou(1), "live, with no poll having run")

        // The thread is decided: the window's reading changes at once, while the last poll still says one.
        await store.readRailSummaries()
        try open.decide("n0", "accepted")
        await store.reload()
        #expect(store.railBadge(for: open.project.root.path) != .needsYou(1), "never behind the list beside it")
    }

    @Test func theProjectTheWindowLeftKeepsTheCountItHadWhileOpen() async throws {
        let first = try await fixture(needsYou: 1)
        let second = try await fixture()
        let store = await store(open: first, others: [second])
        await store.readRailSummaries()
        await store.pickRecent(second.project.root.path)
        #expect(store.railBadge(for: first.project.root.path) == .needsYou(1), "its tile keeps its count once it is not open")
    }

    @Test func aProjectThatIsGoneOrNoLongerOnTheRailHoldsNoCount() async throws {
        let open = try await fixture()
        let other = try await fixture(needsYou: 1)
        let store = await store(open: open, others: [other])
        await store.readRailSummaries()
        #expect(store.railBadge(for: other.project.root.path) == .needsYou(1))

        await store.removeFromRail(other.project.root.path)
        await store.readRailSummaries()
        #expect(store.railBadge(for: other.project.root.path) == .none, "a project off the rail is forgotten")
    }

    @Test func theTasksOfAnotherProjectCountByTheRulesTheRailRowsApply() async throws {
        let open = try await fixture()
        let tasks = try await AppFixture()
        try await AppScenario.tasks.build(in: tasks)
        keptFixtures.append(tasks)
        let expected = RailSummaries.tasks(try TasksReader.entries(tasks.project, now: Date()))
        #expect(expected.needsYou + expected.failed + expected.running > 0, "the tasks scenario holds something worth counting")

        let store = await store(open: open, others: [tasks])
        await store.readRailSummaries()
        let threads = try #require(ProjectSummaryLoader.read(project: tasks.project))
        let total = threads + expected
        let want = RailBadge.from(needsYou: total.needsYou, failed: total.failed, running: total.running > 0)
        #expect(store.railBadge(for: tasks.project.root.path) == want)
    }

    @Test func aFolderThatWentAwayIsForgottenAndOneThatCannotBeListedKeepsItsCount() async throws {
        let open = try await fixture()
        let other = try await fixture(needsYou: 2)
        let store = await store(open: open, others: [other])
        await store.readRailSummaries()
        #expect(store.railBadge(for: other.project.root.path) == .needsYou(2))

        // The threads folder is there but cannot be listed: the last count stands, never zero.
        let threads = other.project.threadsDirectory
        let held = threads.deletingLastPathComponent().appendingPathComponent("threads-held")
        try FileManager.default.moveItem(at: threads, to: held)
        try "x".write(to: threads, atomically: true, encoding: .utf8)
        await store.readRailSummaries()
        #expect(store.railBadge(for: other.project.root.path) == .needsYou(2), "an unreadable folder is not an empty one")

        try FileManager.default.removeItem(at: other.root)
        await store.readRailSummaries()
        #expect(store.railBadge(for: other.project.root.path) == .none, "a folder that is gone has no count; its tile says so")
    }

    @Test func theTopTileCountsEveryProjectOfTheRailTogether() async throws {
        let open = try await fixture(needsYou: 1)
        let api = try await fixture(needsYou: 2)
        let web = try await fixture(running: true)
        let store = await store(open: open, others: [api, web])
        await store.reload()
        await store.readRailSummaries()
        #expect(store.allProjectsBadge() == .needsYou(3), "the open project's own reading and the others' summaries, added")
    }

    @Test func aFailureDoesNotHideWhatNeedsYouOnTheTopTile() async throws {
        let open = try await fixture(needsYou: 4)
        let broken = try await fixture()
        let url = broken.project.eventsURL("g-2026-11-08-bad")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not an event\nnor this\n".write(to: url, atomically: true, encoding: .utf8)
        let store = await store(open: open, others: [broken])
        await store.reload()
        await store.readRailSummaries()
        #expect(store.allProjectsBadge() == .needsYou(4), "four need you; the one that failed is on its own tile")
        #expect(store.railBadge(for: broken.project.root.path) == .failed(1))

        let quiet = try await fixture()
        let onlyFailed = await self.store(open: quiet, others: [broken])
        await onlyFailed.readRailSummaries()
        #expect(onlyFailed.allProjectsBadge() == .failed(1), "with nothing to decide, the failure shows")
    }

    @Test func aReadThatHangsHoldsOneWorkerHoweverManyPollsPassAndIsReleasedWhenItReallyEnds() async {
        let summaries = RailSummaries()
        let latch = DispatchSemaphore(value: 0)
        let finished = Flag()
        #expect(summaries.begin("/p"))
        let answer: Int? = await RailSummaries.raced(
            seconds: 0.2, finished: { finished.set() },
            {
                _ = latch.wait(timeout: .now() + 10)
                return 1
            })
        #expect(answer == nil && !finished.isSet, "the poll gave up, the read has not ended")
        #expect(!summaries.begin("/p"), "the next poll does not start another read of a project still being read")
        latch.signal()
        let ended = await waitUntil(timeout: 5) { finished.isSet }
        #expect(ended, "the read ended by itself")
        summaries.end("/p")
        #expect(summaries.begin("/p"), "and then the project can be read again")
    }

    @Test func aReadThatTakesTooLongGivesNothingAndOneThatDoesNotGivesItsAnswer() async {
        let latch = DispatchSemaphore(value: 0)
        let slow: Int? = await RailSummaries.raced(seconds: 0.2) {
            _ = latch.wait(timeout: .now() + 5)
            return 1
        }
        #expect(slow == nil, "the poll goes on without it")
        latch.signal()
        let quick: Int? = await RailSummaries.raced(seconds: 5) { 2 }
        #expect(quick == 2)
    }
}
