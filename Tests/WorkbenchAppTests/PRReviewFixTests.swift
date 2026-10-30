import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var runs: [String] = []
    func started(_ item: String) { lock.withLock { started.append(item) } }
    func ran(_ thread: String) { lock.withLock { runs.append(thread) } }
    var followUps: [String] { lock.withLock { started } }
    var runThreads: [String] { lock.withLock { runs } }
}

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct PRReviewFixTests {
    private static let plan = FollowUpPlan(pr: 7, round: 1, allowed: 2, budget: 5)

    private func fixing(
        _ findings: String? = "- a bug", verdict: PRReviewVerdict? = .fix, round: Int = 2
    ) -> PRReviewShown {
        PRReviewShown(pr: 7, round: round, verdict: verdict, failure: nil, findings: findings)
    }

    /// A shipped thread `t1`, and a window on it showing a round of findings. Starting a follow-up writes `t2` into the project.
    private func store(
        _ calls: Calls, plan: FollowUpPlan = plan, startError: Error? = nil
    ) async throws -> (ProjectStore, AppFixture) {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "accepted")
        try fixture.ship("t1", number: 7)
        keptFixtures.append(fixture)
        let actions = GoalActions(
            makeRun: { _, thread, _ in
                calls.ran(thread)
                return RunHandle(run: {}, stop: {})
            },
            followUpPlan: { _, _, _ in plan },
            startFollowUp: { _, thread, findings, round in
                if let startError { throw startError }
                calls.started("\(thread) round \(round): \(findings)")
                try await fixture.addThread("t2", approved: true)
                return "t2"
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        store.prReviewShown = fixing()
        return (store, fixture)
    }

    @Test func offeredOnlyForAFixVerdict() {
        #expect(fixing().canFix)
        #expect(!fixing(verdict: .clean).canFix)
        #expect(!fixing(verdict: nil).canFix)
        #expect(!fixing(nil).canFix && !fixing("  \n").canFix)
    }

    @Test func theConfirmCreatesNothingUntilItIsAccepted() async throws {
        let calls = Calls()
        let (store, _) = try await store(calls)
        await store.prepareFollowUp()
        #expect(store.pendingFollowUp == Self.plan)
        store.cancelFollowUp()
        #expect(store.pendingFollowUp == nil)
        // Confirming without the confirm having been read does nothing either.
        await store.confirmFollowUp()
        #expect(calls.followUps.isEmpty && calls.runThreads.isEmpty && store.prReviewShown != nil)
    }

    @Test func theConfirmSaysWhatItStartsAndWhatItCanCost() {
        let text = Self.plan.text
        #expect(text.contains("follow-up 1 of at most 2") && text.contains("#7") && text.contains("$5.00"))
    }

    @Test func confirmingStartsTheFollowUpWithTheRoundsFindings() async throws {
        let calls = Calls()
        let (store, _) = try await store(calls)
        await store.prepareFollowUp()
        await store.confirmFollowUp()
        #expect(calls.followUps == ["t1 round 2: - a bug"])
    }

    @Test func theFollowUpIsShownAndItsTurnStarted() async throws {
        let calls = Calls()
        let (store, _) = try await store(calls)
        await store.prepareFollowUp()
        await store.confirmFollowUp()
        #expect(store.prReviewShown == nil && store.pendingFollowUp == nil)
        #expect(store.currentThread == "t2" && calls.runThreads == ["t2"])
    }

    @Test func aRefusalShowsInTheSheetAndStartsNothing() async throws {
        struct Refused: Error, CustomStringConvertible { var description = "no rounds left" }
        let calls = Calls()
        let (store, _) = try await store(calls, startError: Refused())
        await store.prepareFollowUp()
        await store.confirmFollowUp()
        #expect(store.followUpError == "no rounds left" && store.prReviewShown != nil)
        #expect(calls.followUps.isEmpty && calls.runThreads.isEmpty && store.currentThread == "t1")
    }

    @Test func aPlanWithNoRoundsLeftOffersNoStart() async throws {
        let calls = Calls()
        let none = FollowUpPlan(pr: 7, round: 3, allowed: 2, budget: 5, refusal: "no rounds left")
        let (store, _) = try await store(calls, plan: none)
        await store.prepareFollowUp()
        await store.confirmFollowUp()
        #expect(store.pendingFollowUp?.refusal == "no rounds left" && calls.followUps.isEmpty)
    }

    // MARK: Core itself

    private func coreProject(_ config: String) async throws -> (AppFixture, Project) {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        keptFixtures.append(fixture)
        let project = fixture.project
        try FileManager.default.createDirectory(
            at: project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.write(to: project.configURL, atomically: true, encoding: .utf8)
        return (fixture, project)
    }

    @Test func coreRefusesAThreadWithNoPullRequestInItsOwnWords() async throws {
        let (_, project) = try await coreProject("[tools]\navailable = [\"Read\"]\n")
        do {
            _ = try await GoalActions.core.startFollowUp(project, "t1", "- a bug", 1)
            Issue.record("a thread with no pull request on record started a follow-up")
        } catch {
            #expect("\(error)".contains("no recorded pull request"))
        }
        #expect(ThreadStore(project: project).followUps(of: "t1").isEmpty)
    }

    @Test func coreSaysUpFrontWhenNoRoundsAreLeft() async throws {
        let (_, project) = try await coreProject("[tools]\navailable = [\"Read\"]\n[pr_review]\nmax_rounds = 1\n")
        let plan = try await GoalActions.core.followUpPlan(project, "t1", 7)
        #expect(plan.allowed == 0 && plan.round == 1 && plan.refusal?.contains("max_rounds") == true)
        let (_, open) = try await coreProject("[tools]\navailable = [\"Read\"]\n")
        let planned = try await GoalActions.core.followUpPlan(open, "t1", 7)
        #expect(planned.allowed == 2 && planned.refusal == nil && planned.budget == Config.defaultBudgetUSD)
    }
}
