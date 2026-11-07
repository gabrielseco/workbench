import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptLoggedMergeFixtures: [AppFixture] = []

/// A merge the log recorded is shown by the thread screen without asking GitHub.
@MainActor @Suite struct LoggedMergeScreenTests {
    @Test func aLoggedMergeNeedsNoReadOfGitHubOnTheThreadScreen() async throws {
        let fixture = try await AppFixture()
        keptLoggedMergeFixtures.append(fixture)
        try await fixture.addThread("a", approved: true, title: "Shipped a")
        try fixture.turn("a", 1)
        try fixture.decide("a", "accepted")
        try fixture.ship("a", number: 7)
        let open = ProjectLoader.load(project: fixture.project)
        guard case .thread(let before) = open.screen else { throw Failure.notAThread }
        #expect(before.watchesPullRequest && before.finishedText == "Shipped as PR #7.")
        let head = String(repeating: "a", count: 40)
        try fixture.append("a", .prMerged, data: ["number": 7, "head_sha": .string(head)])
        guard case .thread(let after) = ProjectLoader.load(project: fixture.project).screen else { throw Failure.notAThread }
        #expect(!after.watchesPullRequest && !after.canMerge && after.finishedText == "Merged: PR #7.")
        let github = Reads()
        let store = ProjectStore(
            preferences: MemoryPreferences(),
            actions: GoalActions(pullRequestStatus: { _, _ in github.count += 1; throw Failure.notAThread }))
        #expect(await store.open(fixture.root))
        #expect(!store.pullRequestCIIsDue && github.count < 1)
    }

    @Test func aMergeReadForAProjectThatIsNoLongerOpenIsNeitherWrittenNorKept() async throws {
        let fixture = try await AppFixture()
        keptLoggedMergeFixtures.append(fixture)
        try await fixture.addThread("a", approved: true, title: "Shipped a")
        try fixture.turn("a", 1)
        try fixture.decide("a", "accepted")
        try fixture.ship("a", number: 7)
        let store = ProjectStore(preferences: MemoryPreferences(), actions: GoalActions())
        #expect(await store.open(fixture.root))
        let merged = PRStatus(number: 7, state: .merged, head: String(repeating: "a", count: 40), checks: nil)
        // A generation older than the open project's: the answer belongs to a project that was closed.
        await store.recordMerge(merged, thread: "a", in: fixture.project, generation: store.generation - 1)
        let events = try EventLogReader.read(at: fixture.project.eventsURL("a")).events
        #expect(!events.contains { $0.kind == .prMerged } && store.threads.unwrittenMerges.isEmpty)
        await store.recordMerge(merged, thread: "a", in: fixture.project, generation: store.generation)
        #expect(try EventLogReader.read(at: fixture.project.eventsURL("a")).events.contains { $0.kind == .prMerged })
    }

    private enum Failure: Error { case notAThread }
    private final class Reads: @unchecked Sendable { var count = 0 }
}
