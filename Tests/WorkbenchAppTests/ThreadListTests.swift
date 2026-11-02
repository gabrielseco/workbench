import AppKit
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptThreadListFixtures: [AppFixture] = []

/// The thread list (P22 slice 5): a row per thread read cheaply, and a click that shows a thread and changes nothing else.
@MainActor @Suite struct ThreadListTests {
    private func fixture() async throws -> AppFixture {
        let fixture = try await AppFixture()
        keptThreadListFixtures.append(fixture)
        return fixture
    }

    private func rows(_ fixture: AppFixture, cache: ThreadListLoader.Cache = .init()) -> ThreadListing {
        ThreadListLoader.load(project: fixture.project, cache: cache)
    }

    // MARK: Rows

    @Test func eachThreadIsARowNewestFirstWithItsTitleMarkAndStateLine() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("old", approved: true, title: "The old one")
        try fixture.turn("old", 1)
        try fixture.decide("old", "accepted")
        try await fixture.addThread("draft", title: "A draft")
        try await fixture.addThread("busy", approved: true, title: "Working one")
        try fixture.append("busy", .turnStarted, turn: 1, data: ["session_id": "s1"])
        let listing = rows(fixture)
        #expect(listing.rows.map(\.id) == ["busy", "draft", "old"])
        let byID = Dictionary(uniqueKeysWithValues: listing.rows.map { ($0.id, $0) })
        #expect(byID["old"]?.title == "The old one" && byID["old"]?.line == "Accepted")
        #expect(byID["draft"]?.mark == .needsYou || byID["draft"]?.mark == .idle)
        #expect(byID["draft"]?.line == "Draft · not approved")
        #expect(byID["busy"]?.line == "Working")
    }

    @Test func aThreadWithoutAGoalFileIsNamedByItsIdAndABrokenLogIsMarkedBroken() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("nogoal")
        try FileManager.default.removeItem(at: fixture.project.goalURL("nogoal"))
        try await fixture.addThread("torn")
        try fixture.overwriteLog("torn", with: "this is not an event\n")
        let byID = Dictionary(uniqueKeysWithValues: rows(fixture).rows.map { ($0.id, $0) })
        #expect(byID["nogoal"]?.title == "nogoal")
        #expect(byID["torn"]?.mark == .broken && byID["torn"]?.line == "The log cannot be read")
    }

    @Test func theMarkTellsDoneFromWaitingFromWorking() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("done", approved: true)
        try fixture.turn("done", 1)
        try fixture.decide("done", "accepted")
        try await fixture.addThread("busy", approved: true)
        try fixture.append("busy", .turnStarted, turn: 1, data: ["session_id": "s1"])
        try await fixture.addThread("draft")
        let byID = Dictionary(uniqueKeysWithValues: rows(fixture).rows.map { ($0.id, $0.mark) })
        #expect(byID["done"] == .done && byID["busy"] == .working && byID["draft"] != .done)
        let state = ThreadStore(project: fixture.project).state(of: "draft")
        #expect(ThreadListLoader.mark(attention: .working, state: state, damaged: true) == .broken)
    }

    // MARK: Cost

    @Test func aBigProjectShowsTheNewestRowsReadsOnlyThoseAndAnUnchangedOneReadsNothing() async throws {
        let fixture = try await fixture()
        let total = ThreadListLoader.maxRows + 25
        for number in 0..<total { try await fixture.addThread(String(format: "t%03d", number)) }
        let cache = ThreadListLoader.Cache()
        let first = rows(fixture, cache: cache)
        #expect(first.rows.count == ThreadListLoader.maxRows && first.older == 25)
        let replayed = first.rows.filter { EventLogReadCount.reads(of: fixture.project.eventsURL($0.id)) > 0 }.count
        #expect(replayed == ThreadListLoader.maxRows, "every shown row replayed once")
        let older = (0..<total).map { String(format: "t%03d", $0) }.filter { id in !first.rows.contains { $0.id == id } }
        let olderReads = older.map { EventLogReadCount.reads(of: fixture.project.eventsURL($0)) }
        #expect(olderReads.allSatisfy { $0 == 0 }, "an older thread's log is not replayed")
        let before = first.rows.reduce(0) { $0 + EventLogReadCount.reads(of: fixture.project.eventsURL($1.id)) }
        _ = rows(fixture, cache: cache)
        let after = first.rows.reduce(0) { $0 + EventLogReadCount.reads(of: fixture.project.eventsURL($1.id)) }
        #expect(after == before, "nothing changed, nothing read")
    }

    @Test func aChangedLogIsReadAgainAndTheOthersAreNot() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("a", approved: true)
        try await fixture.addThread("b", approved: true)
        let cache = ThreadListLoader.Cache()
        _ = rows(fixture, cache: cache)
        let (a, b) = (fixture.project.eventsURL("a"), fixture.project.eventsURL("b"))
        let (aBefore, bBefore) = (EventLogReadCount.reads(of: a), EventLogReadCount.reads(of: b))
        try fixture.append("a", .turnStarted, turn: 1, data: ["session_id": "s1"])
        let listing = rows(fixture, cache: cache)
        #expect(EventLogReadCount.reads(of: a) == aBefore + 1 && EventLogReadCount.reads(of: b) == bBefore)
        #expect(listing.rows.first { $0.id == "a" }?.line == "Working")
    }

    // MARK: Selecting

    private func open(_ fixture: AppFixture) async throws -> ProjectStore {
        let preferences = MemoryPreferences()
        preferences.chatFeed = true
        let store = ProjectStore(preferences: preferences)
        #expect(await store.open(fixture.root))
        return store
    }

    @Test func aClickShowsThatThreadAndHoldsAcrossReloadsUntilAnotherIsPicked() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("old", approved: true, title: "Old")
        try fixture.turn("old", 1)
        try fixture.decide("old", "accepted")
        try await fixture.addThread("new", title: "New")
        let store = try await open(fixture)
        #expect(store.currentThread == "new")
        await store.select(thread: "old")
        #expect(store.currentThread == "old")
        guard case .thread(let shown) = store.screen else { throw Failure.notAThread }
        #expect(shown.id == "old")
        await store.reload()
        #expect(store.currentThread == "old", "a poll does not take the pick away")
        await store.select(thread: "new")
        #expect(store.currentThread == "new")
    }

    @Test func aClickChangesNoLogAndStartsNothing() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("a", approved: true)
        try await fixture.addThread("b")
        let store = try await open(fixture)
        let before = try Data(contentsOf: fixture.project.eventsURL("a"))
        let beforeB = try Data(contentsOf: fixture.project.eventsURL("b"))
        await store.select(thread: "a")
        await store.select(thread: "b")
        #expect(try Data(contentsOf: fixture.project.eventsURL("a")) == before)
        #expect(try Data(contentsOf: fixture.project.eventsURL("b")) == beforeB)
    }

    @Test func aPickedThreadThatDisappearsFallsBackAndAProjectChangeClearsThePick() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("a", title: "A")
        try await fixture.addThread("b", title: "B")
        let store = try await open(fixture)
        await store.select(thread: "a")
        try FileManager.default.removeItem(at: fixture.project.threadDirectory("a"))
        await store.reload()
        #expect(store.currentThread == "b")
        await store.select(thread: "b")
        let other = try await self.fixture()
        try await other.addThread("z", title: "Z")
        #expect(await store.open(other.root))
        #expect(store.selectedThread == nil && store.currentThread == "z")
    }

    @Test func theListFollowsTheLogsWithoutAClick() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("a", approved: true)
        let store = try await open(fixture)
        #expect(store.threads.listing.rows.map(\.line) == ["Waiting"])
        try fixture.append("a", .turnStarted, turn: 1, data: ["session_id": "s1"])
        await store.refreshThreadList()
        #expect(store.threads.listing.rows.first?.line == "Working")
        try await fixture.addThread("b")
        await store.refreshThreadList()
        #expect(store.threads.listing.rows.map(\.id) == ["b", "a"])
    }

    @Test func withThePreviewOffNothingIsListed() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("a")
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(fixture.root))
        #expect(store.threads.listing.rows.isEmpty)
    }

    // MARK: What it draws

    @Test func theRowsDrawEachMarkAndTheSelection() throws {
        func drawn(_ mark: ThreadMark, selected: Bool) throws -> Data? {
            let row = ThreadRow(id: "t", title: "Paginate the list", mark: mark, line: "Working")
            let view = ThreadRowView(row: row, selected: selected) {}.frame(width: 190)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return try #require(renderer.cgImage).dataProvider?.data as Data?
        }
        let marks: [ThreadMark] = [.working, .needsYou, .done, .idle, .broken]
        let images = try marks.map { try drawn($0, selected: false) }
        #expect(Set(images.compactMap { $0 }).count == marks.count, "each mark looks different")
        #expect(try drawn(.working, selected: true) != drawn(.working, selected: false), "the selected row is marked")
    }

    private enum Failure: Error { case notAThread }
}
