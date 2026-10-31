import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var runs: [String] = []
    private var plans = 0
    func started(_ item: String) { lock.withLock { started.append(item) } }
    func ran(_ thread: String) { lock.withLock { runs.append(thread) } }
    func planning() { lock.withLock { plans += 1 } }
    var planReads: Int { lock.withLock { plans } }
    var followUps: [String] { lock.withLock { started } }
    var runThreads: [String] { lock.withLock { runs } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var log: [String] { lock.withLock { items } }
}

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct PRReviewFixTests {
    private nonisolated static let plan = FollowUpPlan(pr: 7, round: 1, allowed: 2, budget: 5)

    private func fixing(
        _ findings: String? = "- a bug", verdict: PRReviewVerdict? = .fix, round: Int = 2
    ) -> PRReviewShown {
        PRReviewShown(pr: 7, round: round, verdict: verdict, failure: nil, findings: findings)
    }

    /// A shipped thread `t1`, and a window on it showing a round of findings. Starting a follow-up writes `t2` into the project.
    private func store(
        _ calls: Calls, plan: FollowUpPlan = plan, startError: Error? = nil, planGate: RunGate? = nil
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
            followUpPlan: { _, _, _ in
                calls.planning()
                await planGate?.wait()
                return plan
            },
            startFollowUp: { _, thread, findings, round, _ in
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

    @Test func aPlanStillBeingReadWhenTheSheetClosesIsDropped() async throws {
        let calls = Calls()
        let gate = RunGate()
        let (store, _) = try await store(calls, planGate: gate)
        for how in ["close", "not now"] {
            store.prReviewShown = fixing()
            let before = calls.planReads
            let reading = Task { await store.prepareFollowUp() }
            for _ in 0..<200 where calls.planReads == before { await Task.yield() }
            #expect(calls.planReads == before + 1)
            if how == "close" { store.closePRReview() } else { store.cancelFollowUp() }
            await gate.open()
            await reading.value
            // What it read belongs to a confirm that is gone: it must not come back on reopening.
            #expect(store.pendingFollowUp == nil, "after \(how)")
            await gate.reset()
        }
    }

    @Test func theConfirmSaysWhatItStartsAndWhatItCanCost() {
        let text = Self.plan.text
        #expect(text.contains("follow-up 1 of at most 2") && text.contains("#7") && text.contains("up to $5.00"))
    }

    @Test func theConfirmSaysWhenThereIsNoDollarCap() {
        let text = FollowUpPlan(pr: 7, round: 1, allowed: 2, budget: nil).text
        #expect(text.contains("no dollar cap") && !text.contains("$"))
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

    // MARK: After the fix round's turn

    private nonisolated static let acceptPlan = AcceptPlan(
        id: "t2", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1",
        diff: .unavailable(reason: "x"), hasPendingChanges: true, commits: [], check: nil, openWork: false,
        snapshot: "s", defaultMessage: "feat: it")
    private nonisolated static let shipPlan = ShipPlan(
        id: "t2", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1", remoteBranch: "workbench/t1",
        base: "origin/main", head: "abcdef1234567890", origin: "git@example.test:me/repo.git", remote: .absent,
        pullRequest: nil)

    /// A window that confirms a fix round whose turn ends with `result` (and a check with `check`, when given), and records
    /// what the decisions after it were called with, in order.
    private func fixRound(
        result: String = "succeeded", check: String? = nil, acceptError: Error? = nil, herdrHeld: RunGate? = nil,
        herdrFails: Bool = false
    ) async throws -> (ProjectStore, Recorder) {
        let recorder = Recorder()
        // Without a held action the turn ends at once; with one, it ends only after "Open in Herdr" has begun.
        let turnGate = RunGate()
        if herdrHeld == nil { await turnGate.open() }
        // With `herdrFails`, the run returns only after Herdr's failure is on screen: it fails between the turn and the round.
        let runReturns = RunGate()
        if !herdrFails { await runReturns.open() }
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "accepted")
        try fixture.ship("t1", number: 7)
        keptFixtures.append(fixture)
        let actions = GoalActions(
            makeRun: { _, thread, _ in
                RunHandle(
                    run: {
                        try await MainActor.run { try fixture.append(thread, .turnStarted, turn: 1, data: ["session_id": "s1"]) }
                        await turnGate.wait()
                        try await MainActor.run {
                            try fixture.append(thread, .turnEnded, turn: 1, data: ["result": .string(result)])
                            if let check { try fixture.append(thread, .checkRan, turn: 1, data: ["result": .string(check)]) }
                        }
                        if herdrFails { await herdrHeld?.open() }
                        await runReturns.wait()
                    }, stop: {})
            },
            openInHerdr: { _, _ in
                await herdrHeld?.wait()
                if herdrFails { throw HerdrFailure(message: "Herdr went away") }
                return GoalActions.HerdrOpenAnswer(
                    opened: HerdrOpened(space: "sp1", alreadyOpen: false), projectInstead: false)
            },
            acceptPlan: { _, thread in
                recorder.add("plan \(thread)")
                return Self.acceptPlan
            },
            accept: { _, thread, _, message in
                if let acceptError { throw acceptError }
                recorder.add("accept \(thread): \(message ?? "default")")
                try await MainActor.run { try fixture.decide(thread, "accepted") }
                return AcceptResult(branch: "workbench/t1", commit: "c0ffee", committedNow: true)
            },
            shipPreview: { _, thread in
                recorder.add("preview \(thread)")
                return ShipPreview(plan: Self.shipPlan, description: nil, title: "t", body: "b", note: nil)
            },
            ship: { _, thread, shown in
                recorder.add("ship \(thread)")
                return ShipOutcome(
                    push: ShipPushResult(plan: shown.plan, outcome: .pushed, ahead: nil),
                    pr: ShipPRResult(plan: shown.plan, url: "https://example.test/pull/7", number: 7, outcome: .existing))
            },
            prReview: { _, thread in
                recorder.add("review \(thread)")
                return PRReviewShown(pr: 7, round: 3, verdict: .clean, failure: nil, findings: "all good")
            },
            followUpPlan: { _, _, _ in Self.plan },
            startFollowUp: { _, _, _, _, _ in
                try await fixture.addThread("t2", approved: true)
                return "t2"
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        store.prReviewShown = fixing()
        await store.prepareFollowUp()
        await store.confirmFollowUp()
        if let herdrHeld {
            // "Open in Herdr" is clicked while the turn runs and is still going when the turn ends.
            for _ in 0..<500 where store.busy != nil {
                await store.reload()
                try await Task.sleep(for: .milliseconds(10))
            }
            let opening = Task { await store.openInHerdr() }
            for _ in 0..<500 where store.busy != "Opening in Herdr…" { try await Task.sleep(for: .milliseconds(10)) }
            #expect(store.busy == "Opening in Herdr…")
            await turnGate.open()
            if herdrFails {
                // The turn has ended and Herdr's failure is the error line before the run hands over to the round.
                await opening.value
                #expect(store.actionError != nil && store.runningHere && store.fixRoundToShip != nil)
                await runReturns.open()
            } else {
                for _ in 0..<500 where store.runningHere { try await Task.sleep(for: .milliseconds(10)) }
                try await Task.sleep(for: .milliseconds(50))
                #expect(recorder.log.isEmpty && store.fixRoundToShip != nil, "the round went on while Herdr was opening")
                await herdrHeld.open()
                await opening.value
            }
        }
        // The run ends on its own task: wait, bounded, until what follows it is done.
        for _ in 0..<500 where store.fixRoundToShip != nil || store.runningHere {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.fixRoundToShip == nil && store.busy == nil)
        return (store, recorder)
    }

    @Test func aFixRoundThatSucceedsIsAcceptedShippedAndReviewedWithoutAsking() async throws {
        let (store, recorder) = try await fixRound(check: "passed")
        #expect(
            recorder.log == [
                "plan t2", "accept t2: fix: address review round 2", "preview t2", "ship t2", "review t2",
            ])
        #expect(store.prReviewShown?.round == 3 && store.actionError == nil && store.busy == nil)
    }

    @Test func aFixRoundWaitsForAnActionStillGoingWhenItsTurnEnds() async throws {
        let (store, recorder) = try await fixRound(check: "passed", herdrHeld: RunGate())
        #expect(
            recorder.log == [
                "plan t2", "accept t2: fix: address review round 2", "preview t2", "ship t2", "review t2",
            ])
        #expect(store.prReviewShown?.round == 3 && store.actionError == nil)
    }

    @Test func aFailedActionAfterTheTurnEndedDoesNotStopTheFixRound() async throws {
        let (store, recorder) = try await fixRound(check: "passed", herdrHeld: RunGate(), herdrFails: true)
        #expect(
            recorder.log == [
                "plan t2", "accept t2: fix: address review round 2", "preview t2", "ship t2", "review t2",
            ])
        #expect(store.prReviewShown?.round == 3)
    }

    @Test func aFixRoundWhoseTurnFailedIsLeftForThePerson() async throws {
        let (store, recorder) = try await fixRound(result: "failed")
        #expect(recorder.log.isEmpty)
        #expect(store.currentThread == "t2" && store.notice?.contains("nothing was pushed") == true)
    }

    @Test func aFixRoundWhoseCheckFailedIsNotPushed() async throws {
        let (store, recorder) = try await fixRound(check: "failed")
        #expect(recorder.log.isEmpty)
        #expect(store.notice?.contains("check did not pass") == true)
    }

    @Test func aRefusedAcceptStopsTheRoundBeforeShipping() async throws {
        struct Refused: Error, CustomStringConvertible { var description = "the work changed" }
        let (store, recorder) = try await fixRound(acceptError: Refused())
        #expect(recorder.log == ["plan t2"])
        #expect(store.actionError == "the work changed" && store.prReviewShown == nil)
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
            _ = try await GoalActions.core.startFollowUp(project, "t1", "- a bug", 1, nil)
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
        #expect(planned.allowed == 2 && planned.refusal == nil && planned.budget == nil)
    }

    @Test func coreRefusesToStartDearerThanTheConfirmShowed() async throws {
        let (_, project) = try await coreProject("default_budget_usd = 9\n\n[tools]\navailable = [\"Read\"]\n")
        let shown = try await GoalActions.core.followUpPlan(project, "t1", 7)
        #expect(shown.budget == 9)
        // The config changed while the confirm was open: what it showed is not what would start.
        try "default_budget_usd = 50\n\n[tools]\navailable = [\"Read\"]\n".write(
            to: project.configURL, atomically: true, encoding: .utf8)
        do {
            _ = try await GoalActions.core.startFollowUp(project, "t1", "- a bug", 1, shown.budget)
            Issue.record("a follow-up started with a different budget than the one shown")
        } catch {
            #expect("\(error)".contains("budget changed"))
        }
    }

    @Test func aNoPullRequestRefusalFromCoreReachesTheSheetThroughTheStore() async throws {
        let (fixture, _) = try await coreProject("[tools]\navailable = [\"Read\"]\n")
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: .core)
        #expect(await store.open(fixture.root))
        store.prReviewShown = fixing()
        await store.prepareFollowUp()
        await store.confirmFollowUp()
        #expect(store.followUpError?.contains("no recorded pull request") == true)
        #expect(store.prReviewShown != nil && store.currentThread == "t1" && !store.runningHere)
        #expect(ThreadStore(project: fixture.project).followUps(of: "t1").isEmpty)
    }

    @Test func approvingWhileARunIsGoingDoesNotReopenTheSendBackCard() async throws {
        let gate = RunGate()
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        keptFixtures.append(fixture)
        let actions = GoalActions(makeRun: { _, _, _ in RunHandle(run: { await gate.wait() }, stop: {}) })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        await store.approveAndRun()
        #expect(store.runningHere)
        // A note left from an earlier send must not bring the card back for an approve that was refused.
        store.sendBackNote = "left over"
        await store.approveAndRun()
        #expect(store.actionError == "A run is already going." && !store.sendingBack)
        await gate.open()
    }
}

private actor RunGate {
    func reset() { opened = false }
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
