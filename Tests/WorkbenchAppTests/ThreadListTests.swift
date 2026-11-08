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
        try await fixture.addThread("thrown", approved: true)
        try fixture.decide("thrown", "discarded")
        let byID = Dictionary(uniqueKeysWithValues: rows(fixture).rows.map { ($0.id, $0.mark) })
        #expect(byID["thrown"] == .idle, "discarded work is not green")
        #expect(byID["done"] == .done && byID["busy"] == .working && byID["draft"] != .done)
        let state = ThreadStore(project: fixture.project).state(of: "draft")
        #expect(ThreadListLoader.mark(attention: .working, state: state, damaged: true) == .broken)
    }

    // MARK: The pull request's fate

    private static let head = "h1"

    /// Accepted, shipped as #7, and its pull request review found things to fix, at the head GitHub reports.
    private func shippedWithFindings(_ fixture: AppFixture, _ id: String) async throws {
        try await fixture.addThread(id, approved: true, title: "Shipped \(id)")
        try fixture.turn(id, 1)
        try fixture.decide(id, "accepted")
        try fixture.ship(id, number: 7)
        let round: [String: JSONValue] = ["round": 1, "pr": 7, "head_sha": .string(Self.head)]
        try fixture.append(id, .prReviewStarted, data: .object(round))
        var finished = round
        (finished["ok"], finished["verdict"]) = (true, "fix")
        try fixture.append(id, .prReviewFinished, data: .object(finished))
    }

    private func status(_ state: PRState, number: Int = 7) -> PRStatus {
        PRStatus(number: number, state: state, head: Self.head, checks: nil)
    }

    @Test func mergedPullRequestShowsTick() async throws {
        let fixture = try await fixture()
        try await shippedWithFindings(fixture, "a")
        let listing = ThreadListLoader.load(project: fixture.project, cache: .init(), pullRequests: ["a": status(.merged)])
        let row = try #require(listing.rows.first)
        #expect(row.mark == .done && row.line == "PR #7 merged", "\(row)")
        #expect(row.pullRequest == nil, "a merged pull request is not asked about again")
        // A closed one is over, not green.
        let closed = ThreadListLoader.load(project: fixture.project, cache: .init(), pullRequests: ["a": status(.closed)])
        #expect(closed.rows.first?.mark == .idle && closed.rows.first?.line == "PR #7 closed")
    }

    @Test func openPullRequestWithFindingsNeedsAttention() async throws {
        let fixture = try await fixture()
        try await shippedWithFindings(fixture, "a")
        for read in [nil, status(.open)] {
            let pullRequests = read.map { ["a": $0] } ?? [:]
            let row = try #require(
                ThreadListLoader.load(project: fixture.project, cache: .init(), pullRequests: pullRequests).rows.first)
            #expect(row.mark == .needsYou && row.line == "Needs you · Findings open", "\(String(describing: read))")
            #expect(row.pullRequest == 7, "still open, so it is read again")
        }
    }

    /// What the stand-in GitHub answers, changed by the test between reads.
    private final class GitHub: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Result<PRStatus, Error>
        private(set) var reads = 0
        init(_ answer: Result<PRStatus, Error>) { self.answer = answer }
        func set(_ answer: Result<PRStatus, Error>) { lock.withLock { self.answer = answer } }
        func read() throws -> PRStatus {
            try lock.withLock {
                reads += 1
                return answer
            }
            .get()
        }
    }

    private func store(_ fixture: AppFixture, _ github: GitHub) async throws -> ProjectStore {
        let store = ProjectStore(
            preferences: MemoryPreferences(), actions: GoalActions(pullRequestStatus: { _, _ in try github.read() }))
        #expect(await store.open(fixture.root))
        return store
    }

    @Test func refreshUpdatesPullRequestStatus() async throws {
        let fixture = try await fixture()
        try await shippedWithFindings(fixture, "a")
        try await fixture.addThread("draft")
        let github = GitHub(.success(status(.open)))
        let store = try await store(fixture, github)
        #expect(store.pullRequestsAreDue, "never read")
        await store.refreshPullRequests()
        #expect(github.reads == 1, "only the shipped thread is asked about")
        #expect(store.threads.listing.rows.first { $0.id == "a" }?.mark == .needsYou)
        #expect(!store.pullRequestsAreDue, "read just now")
        github.set(.success(status(.merged)))
        await store.refreshPullRequests(force: true)
        let row = store.threads.listing.rows.first { $0.id == "a" }
        #expect(row?.mark == .done && row?.line == "PR #7 merged")
        await store.refreshPullRequests(force: true)
        #expect(github.reads == 2, "a merge is final: not asked about again")
    }

    @Test func aMergeIsWrittenToTheLogSoTheNextLaunchKnowsItWithoutAskingGitHub() async throws {
        struct Offline: Error {}
        let fixture = try await fixture()
        try await shippedWithFindings(fixture, "a")
        await (try await store(fixture, GitHub(.success(status(.merged))))).refreshPullRequests()
        let events = try EventLogReader.read(at: fixture.project.eventsURL("a")).events
        #expect(events.filter { $0.kind == .prMerged }.count == 1)
        let github = GitHub(.failure(Offline()))
        let second = try await store(fixture, github)
        let row = second.threads.listing.rows.first { $0.id == "a" }
        #expect(row?.mark == .done && row?.line == "PR #7 merged" && github.reads == 0 && !second.pullRequestsAreDue)
    }

    @Test func unavailablePullRequestStatus() async throws {
        struct Offline: Error {}
        let fixture = try await fixture()
        try await shippedWithFindings(fixture, "a")
        let github = GitHub(.failure(Offline()))
        let store = try await store(fixture, github)
        await store.refreshPullRequests()
        #expect(github.reads == 1)
        #expect(store.threads.listing.rows.first?.mark == .needsYou, "not known to be merged, so its findings still ask")
        // A status that was read, then a read that fails: what was known is forgotten, not kept as the answer.
        github.set(.success(status(.open)))
        await store.refreshPullRequests(force: true)
        github.set(.failure(Offline()))
        await store.refreshPullRequests(force: true)
        #expect(store.threads.pullRequests["a"] == nil && store.threads.listing.rows.first?.mark == .needsYou)
        // A merged status for another pull request number says nothing of this one.
        let other = ThreadListLoader.load(
            project: fixture.project, cache: .init(), pullRequests: ["a": status(.merged, number: 6)])
        #expect(other.rows.first?.mark == .needsYou)
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

    @Test func theArrowKeysStepToTheNeighbourAndStopAtTheEnds() {
        let ids = ["a", "b", "c"]
        #expect(InboxModel.neighbour(of: "b", in: ids, up: true) == "a")
        #expect(InboxModel.neighbour(of: "b", in: ids, up: false) == "c")
        #expect(InboxModel.neighbour(of: "a", in: ids, up: true) == nil)
        #expect(InboxModel.neighbour(of: "c", in: ids, up: false) == nil)
        #expect(InboxModel.neighbour(of: nil, in: ids, up: false) == nil)
    }

    @Test func whatWasReadForOneProjectIsNotUsedForAnother() async throws {
        let first = try await fixture()
        try await first.addThread("fix", title: "First")
        let second = try await fixture()
        try await second.addThread("fix", title: "Second")
        let store = try await open(first)
        #expect(store.threads.listing.rows.map(\.title) == ["First"])
        #expect(await store.open(second.root))
        #expect(store.threads.listing.rows.map(\.title) == ["Second"])
    }

    @Test func anApprovalThatFailsAfterAnotherThreadWasPickedSaysSoOnItsOwnThread() async throws {
        struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }
        let (stream, release) = AsyncStream<Void>.makeStream()
        let fixture = try await fixture()
        try await fixture.addThread("b", title: "B")
        try await fixture.addThread("a", title: "A")
        let preferences = MemoryPreferences()
        let store = ProjectStore(
            preferences: preferences,
            actions: GoalActions(approve: { _, _ in
                for await _ in stream { break }
                throw Refused()
            }))
        #expect(await store.open(fixture.root))
        let starting = Task { await store.approveAndRun() }
        for _ in 0..<200 where store.busy == nil { try await Task.sleep(for: .milliseconds(10)) }
        await store.select(thread: "b")
        release.yield()
        await starting.value
        let key = ThreadSession.Key(project: fixture.project, thread: "a")
        #expect(store.sessions[key]?.actionError == "refused")
        #expect(store.actionError == nil, "the thread on screen is not told about another's approval")
    }

    @Test func anApprovedGoalTooLongToParseWholeIsStillApprovedInItsRow() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("big", approved: true, title: "Big", request: String(repeating: "word ", count: 40_000))
        let row = rows(fixture).rows.first
        #expect(row?.title == "Big" && row?.line == "Waiting", "approved, nothing run: not a draft")
    }

    @Test func aGoalTooLongToParseWholeStillGivesItsRowATitleFromItsFirstBytes() async throws {
        let fixture = try await fixture()
        try await fixture.addThread("big", title: "The big one", request: String(repeating: "word ", count: 40_000))
        #expect(try Data(contentsOf: fixture.project.goalURL("big")).count > ThreadListLoader.goalHeadBytes)
        #expect(rows(fixture).rows.first?.title == "The big one")
    }

    @Test func aRunThatCannotStartSaysSoOnItsOwnThreadEvenIfAnotherIsOnScreenByThen() async throws {
        struct Cannot: Error, CustomStringConvertible { var description: String { "no claude" } }
        let (stream, release) = AsyncStream<Void>.makeStream()
        let fixture = try await fixture()
        try await fixture.addThread("b", title: "B")
        try await fixture.addThread("a", approved: false, title: "A")
        let preferences = MemoryPreferences()
        let store = ProjectStore(
            preferences: preferences,
            actions: GoalActions(
                approve: { _, _ in for await _ in stream { break } },
                makeRun: { _, _, _ in throw Cannot() }))
        #expect(await store.open(fixture.root))
        #expect(store.currentThread == "a")
        let starting = Task { await store.approveAndRun() }
        for _ in 0..<200 where store.busy == nil { try await Task.sleep(for: .milliseconds(10)) }
        await store.select(thread: "b")
        release.yield()
        await starting.value
        let key = ThreadSession.Key(project: fixture.project, thread: "a")
        for _ in 0..<200 where store.sessions[key]?.actionError == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.sessions[key]?.actionError == "The run did not start: no claude")
        #expect(store.actionError == nil, "the thread on screen is not told about another's run")
    }

    // MARK: What it draws

    @Test func theRowsDrawEachMarkAndTheSelection() throws {
        func drawn(_ mark: ThreadMark, selected: Bool) throws -> Data? {
            let row = ThreadRow(id: "t", title: "Paginate the list", mark: mark, line: "Working")
            let view = RailRowView(row: RailRow.thread(row), selected: selected) {}.frame(width: 190)
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
