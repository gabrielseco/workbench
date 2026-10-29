import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptPRReviewFixtures: [AppFixture] = []

/// After a ship the window opens the pull request and has Codex review it; what it found is shown, and nothing is posted.
@MainActor @Suite struct PRReviewScreenTests {
    private nonisolated static let clean = PRReviewShown(
        pr: 7, round: 1, verdict: .clean, failure: nil, findings: "Nothing to fix.\nVERDICT: CLEAN")

    private func shipped(_ actions: GoalActions) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        keptPRReviewFixtures.append(fixture)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "accepted")
        try fixture.ship("t1", number: 7)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    private func snapshot(_ store: ProjectStore) -> ThreadSnapshot? {
        guard case .thread(let shown) = store.screen else { return nil }
        return shown
    }

    @Test func aShippedThreadLinksToItsPullRequestAndCanBeReviewed() async throws {
        let store = try await shipped(GoalActions())
        let shown = try #require(snapshot(store))
        #expect(shown.pullRequestURL?.absoluteString == "https://example.test/pull/7")
        #expect(shown.canReviewPullRequest && shown.prReviewText == nil)
    }

    @Test func aThreadWithoutAPullRequestOrAfterCleaningHasNothingToReview() async throws {
        let fixture = try await AppFixture(git: false)
        keptPRReviewFixtures.append(fixture)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "accepted")
        guard case .thread(let accepted) = ProjectLoader.load(project: fixture.project).screen else { return }
        #expect(!accepted.canReviewPullRequest && accepted.pullRequestURL == nil)
    }

    @Test func reviewingShowsWhatCodexFoundAndRunsOnceForTheOpenThread() async throws {
        let calls = Counter()
        let store = try await shipped(
            GoalActions(prReview: { _, thread in
                calls.add(thread)
                return Self.clean
            }))
        await store.reviewPullRequest()
        #expect(store.prReviewShown == Self.clean && calls.all == ["t1"])
        #expect(store.actionError == nil && store.busy == nil)
        store.closePRReview()
        #expect(store.prReviewShown == nil)
    }

    @Test func aRefusedReviewIsSaidInCoresWordsAndShowsNoFindings() async throws {
        let store = try await shipped(
            GoalActions(prReview: { _, _ in throw GoalActions.RefusalText("round 1 reviewed the branch as it is now") }))
        await store.reviewPullRequest()
        #expect(store.prReviewShown == nil && store.actionError == "round 1 reviewed the branch as it is now")
    }

    @Test func aRoundWithoutAVerdictIsAFailureNeverAPass() {
        let shown = PRReviewShown(pr: 7, round: 2, verdict: nil, failure: "codex timed out", findings: nil)
        #expect(shown.headline == "Pull request #7: no verdict (round 2): codex timed out")
        #expect(Self.clean.headline == "Pull request #7: clean (round 1)")
    }

    @Test func aReopenedRoundKeepsItsReasonAndSaysWhenTheBranchMovedOn() {
        let record = PRReviewRecord(thread: "t1", round: 2, pr: 7, ok: false, verdict: nil, headSHA: "aaaaaaa1111")
        let failed = PRReviewShown(record, findings: nil, failure: "codex timed out", tip: "bbbbbbb2222")
        #expect(failed.headline == "Pull request #7: no verdict (round 2): codex timed out")
        #expect(failed.notes.count == 1 && failed.notes[0].hasPrefix("Stale: the branch has moved"))
        let current = PRReviewShown(record, findings: nil, failure: "x", tip: "aaaaaaa1111")
        #expect(current.notes.isEmpty)
        let unknownTip = PRReviewShown(record, findings: nil, failure: "x", tip: nil)
        #expect(unknownTip.notes.isEmpty, "a tip that cannot be read is not called stale")
    }

    @Test func anEarlierRoundCanBeOpenedAgain() async throws {
        let store = try await shipped(GoalActions(latestPRReview: { _, _ in Self.clean }))
        await store.showPRReview()
        #expect(store.prReviewShown == Self.clean)
    }

    @Test func openingARoundThatNeverRanSaysSo() async throws {
        let store = try await shipped(GoalActions())
        await store.showPRReview()
        #expect(store.prReviewShown == nil && store.actionError != nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}
