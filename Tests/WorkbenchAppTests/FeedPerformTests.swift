import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptPerformFixtures: [AppFixture] = []

/// Each button of the decision card runs the action the step screen's button runs, and is refused for the same reasons.
@MainActor @Suite struct FeedPerformTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
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

    private nonisolated static let acceptPlan = AcceptPlan(
        id: "t1", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1", diff: .unavailable(reason: "x"),
        hasPendingChanges: true, commits: [], check: nil, openWork: false, snapshot: "s", defaultMessage: "m")
    private nonisolated static let discardPlan = DiscardPlan(
        id: "t1", worktree: nil, branch: nil, diff: .unavailable(reason: "x"), commits: [])
    private nonisolated static let preview = ShipPreview(
        plan: ShipPlan(
            id: "t1", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1", remoteBranch: "workbench/t1",
            base: "origin/main", head: "abcdef1234567890", origin: "git@example.test:me/repo.git", remote: .absent,
            pullRequest: nil),
        description: nil, title: "feat: it", body: "Body.", note: nil)

    private func store(_ calls: Calls, gate: Gate? = nil, acceptError: Error? = nil) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        keptPerformFixtures.append(fixture)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        let actions = GoalActions(
            approve: { _, _ in calls.add("approve") },
            makeRun: { _, _, _ in
                calls.add("makeRun")
                return RunHandle(run: {}, stop: {})
            },
            requestStop: { _, _ in
                calls.add("requestStop")
                return true
            },
            openWorktree: { _, _ in calls.add("openWorktree") },
            openInHerdr: { _, _ in
                calls.add("openInHerdr")
                return GoalActions.HerdrOpenAnswer(opened: HerdrOpened(space: "s", alreadyOpen: false), projectInstead: false)
            },
            openDiff: { _, _, _ in
                calls.add("openDiff")
                return nil
            },
            acceptPlan: { _, _ in
                calls.add("acceptPlan")
                if let gate { await gate.wait() }
                return Self.acceptPlan
            },
            accept: { _, _, _, _ in
                calls.add("accept")
                if let acceptError { throw acceptError }
                return AcceptResult(branch: "b", commit: "c", committedNow: true)
            },
            discardPlan: { _, _ in
                calls.add("discardPlan")
                return Self.discardPlan
            },
            discard: { _, _, _ in calls.add("discard") },
            shipPreview: { _, _ in
                calls.add("shipPreview")
                return Self.preview
            },
            ship: { _, _, shown in
                calls.add("ship")
                return ShipOutcome(
                    push: ShipPushResult(plan: shown.plan, outcome: .pushed, ahead: nil),
                    pr: ShipPRResult(plan: shown.plan, url: "https://example.test/pull/7", number: 7, outcome: .created))
            },
            prReview: { _, _ in
                calls.add("prReview")
                throw PerformError.stop
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    private enum PerformError: Error { case stop }

    @Test func eachButtonRunsTheActionTheStepScreenRuns() async throws {
        let table: [(FeedAction.Kind, [String])] = [
            (.approveAndRun, ["approve", "makeRun"]), (.stopTurn, ["requestStop"]), (.accept, ["acceptPlan", "accept"]),
            (.acceptAndShip, ["acceptPlan", "accept", "shipPreview", "ship"]),
            (.ship, ["shipPreview", "ship"]), (.reviewPR, ["prReview"]), (.discard, ["discardPlan"]),
            (.openDiff, ["openDiff"]), (.openWorktree, ["openWorktree"]), (.openHerdr, ["openInHerdr"]), (.runAgain, ["makeRun"]),
        ]
        for (kind, expected) in table {
            let calls = Calls()
            let store = try await store(calls)
            await store.perform(kind)
            #expect(calls.all == expected, "\(kind.rawValue) ran \(calls.all)")
        }
    }

    @Test func acceptAndShipStopsAtAnAcceptThatFailed() async throws {
        let calls = Calls()
        let store = try await store(calls, acceptError: PerformError.stop)
        await store.perform(.acceptAndShip)
        #expect(calls.all == ["acceptPlan", "accept"], "nothing is shipped from a thread that was not accepted")
        #expect(store.actionError != nil && store.notice == nil)
    }

    @Test func acceptAndShipDoesNotShipAnotherThreadWhenTheWindowMovedOn() async throws {
        let calls = Calls()
        let gate = Gate()
        let store = try await store(calls, gate: gate)
        let fixture = keptPerformFixtures.last!
        try await fixture.addThread("t2", approved: true)
        try fixture.turn("t2", 1)
        await store.select(thread: "t1")
        let pressed = Task { await store.perform(.acceptAndShip) }
        for _ in 0..<400 where calls.all != ["acceptPlan"] { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls.all == ["acceptPlan"], "the accept never started")
        await store.select(thread: "t2")
        await gate.open()
        await pressed.value
        #expect(!calls.all.contains("ship"), "the thread on screen is not the one that was accepted")
    }

    @Test func openPROpensTheThreadsPullRequestAndNothingElse() async throws {
        let calls = Calls()
        let store = try await store(calls)
        var opened: [URL] = []
        store.openExternal = { opened.append($0) }
        await store.perform(.openPR)
        #expect(opened.isEmpty, "a thread with no pull request opens nothing")

        let fixture = try await AppFixture()
        keptPerformFixtures.append(fixture)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "accepted")
        try fixture.ship("t1", number: 7)
        guard case .thread(var shipped) = ProjectLoader.load(project: Project(root: fixture.root)).screen,
            let record = shipped.state.pullRequest
        else { Issue.record("no shipped thread"); return }
        store.screen = .thread(shipped)
        await store.perform(.openPR)
        #expect(opened == [URL(string: record.url)!])

        opened = []
        shipped.state.pullRequest?.url = "file:///etc/passwd"
        store.screen = .thread(shipped)
        await store.perform(.openPR)
        #expect(opened.isEmpty, "only a web address is opened")
    }

    @Test func theCardOnlyOpensWhatNeedsAViewToOpen() async throws {
        let calls = Calls()
        let store = try await store(calls)
        await store.perform(.newGoal)
        #expect(store.newThread)
        await store.perform(.sendGuidance)
        #expect(store.actionError == "Say what to change: a note is required.", "an empty field sends nothing")
        await store.perform(.reviewDetails)
        #expect(calls.all.isEmpty, "the review's details are the view's to open")
    }

    @Test func discardAsksForConfirmationAndRemovesNothingOnTheFirstPress() async throws {
        let calls = Calls()
        let store = try await store(calls)
        await store.perform(.discard)
        #expect(store.pendingDiscard != nil && calls.all == ["discardPlan"], "the plan is shown; discard has not run")
    }

    @Test func confirmingTheDiscardRunsTheSameDiscardAsTheStepScreen() async throws {
        let calls = Calls()
        let store = try await store(calls)
        await store.perform(.discard)
        await store.confirmDiscard()
        #expect(calls.all == ["discardPlan", "discard"] && store.pendingDiscard == nil)
        await store.perform(.discard)
        store.cancelDiscard()
        #expect(calls.all == ["discardPlan", "discard", "discardPlan"], "cancelling removes nothing")
    }

    @Test func aSecondPressWhileOneIsGoingOnIsRefusedAsOnTheStepScreen() async throws {
        let (calls, gate) = (Calls(), Gate())
        let store = try await store(calls, gate: gate)
        let first = Task { await store.perform(.accept) }
        for _ in 0..<200 where store.busy == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.busy != nil)
        let context = store.feedContext(for: try thread(store))
        #expect(context.busy)
        #expect(FeedActions.derive(context).primary?.enabled != true, "the card disables the button for the same reason")
        await store.perform(.accept)
        await gate.open()
        await first.value
        #expect(calls.all.filter { $0 == "acceptPlan" }.count == 1, "the second press started nothing")
    }

    private func thread(_ store: ProjectStore) throws -> ThreadSnapshot {
        guard case .thread(let shown) = store.screen else { throw PerformError.stop }
        return shown
    }
}
