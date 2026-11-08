import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptGitHubFixtures: [AppFixture] = []

/// What GitHub said of a project's pull requests belongs to the project: it survives a switch, and it is read for the rail's other
/// projects in the background.
@MainActor @Suite struct GitHubPerProjectTests {
    nonisolated private static let head = String(repeating: "a", count: 40)

    private final class GitHub: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        var state: PRState = .closed
        var reads: [String] { lock.withLock { asked } }
        func read(_ project: Project, _ thread: String) -> PRStatus {
            lock.withLock { asked.append("\(project.root.lastPathComponent)/\(thread)") }
            return PRStatus(number: 7, state: state, head: GitHubPerProjectTests.head, checks: nil)
        }
    }

    /// A project with one thread shipped as PR #7 and reviewed with findings: it asks for you until GitHub says it is over.
    private func shipped() async throws -> AppFixture {
        let fixture = try await AppFixture()
        keptGitHubFixtures.append(fixture)
        try await fixture.addThread("a", approved: true, title: "Shipped a")
        try fixture.turn("a", 1)
        try fixture.decide("a", "accepted")
        try fixture.ship("a", number: 7)
        let round: [String: JSONValue] = ["round": 1, "pr": 7, "head_sha": .string(Self.head)]
        try fixture.append("a", .prReviewStarted, data: .object(round))
        var finished = round
        (finished["ok"], finished["verdict"]) = (true, "fix")
        try fixture.append("a", .prReviewFinished, data: .object(finished))
        return fixture
    }

    private func store(_ github: GitHub, open: AppFixture, others: [AppFixture]) async -> ProjectStore {
        let preferences = MemoryPreferences(projectPath: nil)
        preferences.railProjects = ([open] + others).map(\.project.root.path)
        let actions = GoalActions(pullRequestStatus: { project, thread in github.read(project, thread) })
        let store = ProjectStore(preferences: preferences, actions: actions)
        _ = await store.open(open.root)
        return store
    }

    @Test func aSwitchShowsWhatWasKnownAtOnceAndDoesNotAskGitHubAgain() async throws {
        let (first, second) = (try await shipped(), try await shipped())
        let github = GitHub()
        let store = await store(github, open: first, others: [second])
        await store.refreshPullRequests()
        #expect(store.threads.listing.rows.first?.mark == .idle, "closed: over, not asking")
        #expect(github.reads.count == 1)

        _ = await store.open(second.root)
        #expect(store.threads.pullRequests.isEmpty, "the other project has not been asked about")
        _ = await store.open(first.root)
        #expect(store.threads.listing.rows.first?.mark == .idle, "the first list after the switch already has the answer")
        #expect(!store.pullRequestsAreDue && github.reads.count == 1)
    }

    @Test func theOtherProjectsOfTheRailAreAskedAboutInTheBackgroundAndTheirTileFollows() async throws {
        let (open, other) = (try await AppFixture(), try await shipped())
        keptGitHubFixtures.append(open)
        let github = GitHub()
        let store = await store(github, open: open, others: [other])
        await store.readRailSummaries()
        let path = other.project.root.path
        #expect(store.railBadge(for: path) == .needsYou(1), "the logs alone cannot know")

        await store.readOtherProjectsPullRequests()
        #expect(github.reads == ["\(other.root.lastPathComponent)/a"])
        #expect(store.railBadge(for: path) == .none, "GitHub says it is over")

        // Asked about once in the interval, and not again at the next pass.
        await store.readOtherProjectsPullRequests()
        #expect(github.reads.count == 1)
    }

    @Test func aMergeSeenInTheBackgroundIsWrittenToThatProjectsLog() async throws {
        let (open, other) = (try await AppFixture(), try await shipped())
        keptGitHubFixtures.append(open)
        let github = GitHub()
        github.state = .merged
        let store = await store(github, open: open, others: [other])
        await store.readOtherProjectsPullRequests()
        let events = try EventLogReader.read(at: other.project.eventsURL("a")).events
        #expect(events.filter { $0.kind == .prMerged }.count == 1)
    }

    @Test func aPullRequestGitHubSaidClosedIsAskedAboutAgainBecauseItMayBeReopened() async throws {
        let (open, other) = (try await AppFixture(), try await shipped())
        keptGitHubFixtures.append(open)
        let github = GitHub()
        let store = await store(github, open: open, others: [other])
        (store.threads.otherListEvery, store.threads.otherAskEvery) = (.zero, .zero)
        await store.readOtherProjectsPullRequests()
        await store.readOtherProjectsPullRequests()
        #expect(github.reads.count == 2)
    }

    @Test func aThreadPastWhatTheInboxListsIsStillAskedAboutBecauseTheTileCountsIt() async throws {
        let (open, other) = (try await AppFixture(), try await AppFixture())
        keptGitHubFixtures.append(open)
        keptGitHubFixtures.append(other)
        try await other.addThread("a", approved: true, title: "Shipped a")
        try other.turn("a", 1)
        try other.decide("a", "accepted")
        try other.ship("a", number: 7)
        for number in 0..<(ThreadListLoader.maxRows + 5) { try await other.addThread(String(format: "t%03d", number)) }
        let github = GitHub()
        let store = await store(github, open: open, others: [other])
        await store.readOtherProjectsPullRequests()
        #expect(github.reads == ["\(other.root.lastPathComponent)/a"], "the oldest thread, past the 50 the inbox lists")
    }

    @Test func theOpenProjectIsLeftToItsOwnReads() async throws {
        let open = try await shipped()
        let github = GitHub()
        let store = await store(github, open: open, others: [])
        await store.readOtherProjectsPullRequests()
        #expect(github.reads.isEmpty)
    }
}
