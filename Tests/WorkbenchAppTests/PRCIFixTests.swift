import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

/// What the store asked of its actions, in order, and what it handed them.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var fixes: [(failures: [CIFailedTest], budget: Decimal?)] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    func fixed(_ failures: [CIFailedTest], _ budget: Decimal?) { lock.withLock { fixes.append((failures, budget)) } }
    var all: [String] { lock.withLock { items } }
    var started: [(failures: [CIFailedTest], budget: Decimal?)] { lock.withLock { fixes } }
}

/// GitHub as the store sees it: the status each read answers, the next one after the push.
private final class GitHub: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [PRStatus]
    init(_ answers: [PRStatus]) { self.answers = answers }
    func read() -> PRStatus {
        lock.withLock { answers.count > 1 ? answers.removeFirst() : answers[0] }
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

@MainActor private var keptCIFixtures: [AppFixture] = []

@MainActor @Suite struct PRCIFixTests {
    private nonisolated static let head = String(repeating: "a", count: 40)
    private nonisolated static let plan = FollowUpPlan(pr: 7, round: 1, allowed: 2, budget: 5)
    private nonisolated static let failure = CIFailedTest(
        name: "test", workflow: "CI", description: "Process completed with exit code 1.",
        link: "https://github.com/o/r/actions/runs/1/job/2", log: "FAILED: testTotals")

    private nonisolated static func status(_ checks: [(String, String)]) -> PRStatus {
        PRStatus(
            number: 7, state: .open, head: head,
            checks: PRChecksSummary(checks: checks.map { PRCheck(name: $0.0, bucket: $0.1) }))
    }

    private nonisolated static let testFailed = status([("test", "fail"), ("lint", "pass"), ("release-build", "skipping")])

    private nonisolated static let acceptPlan = AcceptPlan(
        id: "t2", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1",
        diff: .unavailable(reason: "x"), hasPendingChanges: true, commits: [], check: nil, openWork: false,
        snapshot: "s", defaultMessage: "feat: it")
    private nonisolated static let shipPlan = ShipPlan(
        id: "t2", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1", remoteBranch: "workbench/t1",
        base: "origin/main", head: "abcdef1234567890", origin: "git@example.test:me/repo.git", remote: .absent,
        pullRequest: nil)

    fileprivate struct Options {
        var github = GitHub([PRCIFixTests.testFailed])
        var failures: Result<[CIFailedTest], GoalActions.RefusalText> = .success([PRCIFixTests.failure])
        var plan = PRCIFixTests.plan
        var startError: GoalActions.RefusalText?
        var turnResult = "succeeded"
        var check: String? = "passed"
        /// Held before the failure details answer, so a test can press again while the first press is going.
        var detailsGate: Gate?
    }

    /// A shipped thread `t1` with a clean review, its CI read once. A CI fix starts `t2`, whose turn ends with `turnResult`, then
    /// accept and ship (recorded on `t2` as the real ones would) and CI is read again.
    private func makeStore(_ log: Log, _ options: Options = Options()) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "accepted")
        try fixture.ship("t1", number: 7)
        try fixture.append(
            "t1", .prReviewFinished,
            data: ["ok": true, "verdict": "clean", "round": 1, "pr": 7, "head_sha": .string(Self.head)])
        keptCIFixtures.append(fixture)
        let o = options
        let actions = GoalActions(
            makeRun: { _, thread, _ in
                log.add("run \(thread)")
                return RunHandle(
                    run: {
                        try await MainActor.run {
                            try fixture.append(thread, .turnStarted, turn: 1, data: ["session_id": "s1"])
                            try fixture.append(thread, .turnEnded, turn: 1, data: ["result": .string(o.turnResult)])
                            if let check = o.check {
                                try fixture.append(thread, .checkRan, turn: 1, data: ["result": .string(check)])
                            }
                        }
                    }, stop: {})
            },
            acceptPlan: { _, thread in
                log.add("plan \(thread)")
                return Self.acceptPlan
            },
            accept: { _, thread, _, message in
                log.add("accept \(thread): \(message ?? "default")")
                try await MainActor.run { try fixture.decide(thread, "accepted") }
                return AcceptResult(branch: "workbench/t1", commit: "c0ffee", committedNow: true)
            },
            shipPreview: { _, _ in ShipPreview(plan: Self.shipPlan, description: nil, title: "t", body: "b", note: nil) },
            ship: { _, thread, shown in
                log.add("ship \(thread)")
                try await MainActor.run { try fixture.ship(thread, number: 7) }
                return ShipOutcome(
                    push: ShipPushResult(plan: shown.plan, outcome: .pushed, ahead: nil),
                    pr: ShipPRResult(plan: shown.plan, url: "https://example.test/pull/7", number: 7, outcome: .existing))
            },
            pullRequestStatus: { _, thread in
                log.add("ci \(thread)")
                return o.github.read()
            },
            prReview: { _, thread in
                log.add("review \(thread)")
                throw GoalActions.Unset()
            },
            followUpPlan: { _, thread, pr in
                log.add("followUpPlan \(thread) #\(pr)")
                return o.plan
            },
            failedTests: { _, thread in
                log.add("failedTests \(thread)")
                await o.detailsGate?.wait()
                return try o.failures.get()
            },
            startCIFix: { _, thread, failures, budget in
                if let error = o.startError { throw error }
                log.add("startCIFix \(thread)")
                log.fixed(failures, budget)
                try await fixture.addThread("t2", approved: true)
                return "t2"
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        await store.refreshPullRequestCI()
        return store
    }

    private func shown(_ store: ProjectStore) throws -> ThreadSnapshot {
        guard case .thread(let snapshot) = store.screen else { throw GoalActions.Unset() }
        return snapshot
    }

    /// Waits, bounded, until the fix round's turn and what follows it are done.
    private func settle(_ store: ProjectStore) async throws {
        for _ in 0..<500 where store.fixRoundToShip != nil || store.runningHere || store.busy != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func startsFixWithFailureDetails() async throws {
        let log = Log()
        let store = try await makeStore(log)
        let decision = store.feedDecision(for: try shown(store))
        #expect(decision.primary?.kind == .fixTests && decision.primary?.enabled == true, "a failed test is offered to fix")
        #expect(decision.more.first { $0.kind == .merge }?.enabled == false, "Merge stays, and stays off")

        await store.perform(.fixTests)
        let started = try #require(log.started.first)
        #expect(started.failures == [Self.failure], "the agent gets the failed test with its link, status and log")
        #expect(started.budget == Self.plan.budget)
        #expect(log.all.prefix(5) == ["ci t1", "failedTests t1", "followUpPlan t1 #7", "startCIFix t1", "run t2"])
        #expect(store.currentThread == "t2")

        try await settle(store)
        // The fix goes onto the pull request's branch through the review loop's own steps: accept, then ship to the same PR.
        let after = Array(log.all.drop { $0 != "run t2" })
        #expect(
            after == ["run t2", "plan t2", "accept t2: fix: make the failed CI tests pass", "ship t2", "ci t2"], "\(after)")
        #expect(!log.all.contains { $0.hasPrefix("review") }, "no PR review is started by a CI fix")
    }

    @Test func reportsProgressAndFailure() async throws {
        // Progress: each phase says what it is doing.
        let gate = Gate()
        var options = Options()
        options.detailsGate = gate
        let log = Log()
        let store = try await makeStore(log, options)
        let pressing = Task { await store.fixFailedTests() }
        for _ in 0..<500 where log.all.last != "failedTests t1" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.ciFixShown(on: "t1")?.phase == .reading && store.ciFixShown(on: "t1")?.line.contains("test") == true)
        #expect(store.busy != nil)
        await gate.open()
        await pressing.value
        try await settle(store)
        #expect(store.ciFixShown(on: "t2")?.phase == .submitted, "the outcome is shown on the fix's screen")

        // A fix that cannot start: why, and what to do, on the CI lines; nothing is started.
        struct Case {
            var name: String
            var options: Options
            var says: String
        }
        var noDetails = Options()
        noDetails.failures = .failure(GoalActions.RefusalText("gh is not signed in"))
        var empty = Options()
        empty.failures = .success([])
        var capped = Options()
        capped.plan = FollowUpPlan(pr: 7, round: 3, allowed: 2, budget: 5, refusal: "no rounds left; raise max_rounds")
        var refused = Options()
        refused.startError = GoalActions.RefusalText("the budget changed")
        for c in [
            Case(name: "details", options: noDetails, says: "gh is not signed in"),
            Case(name: "empty", options: empty, says: "Refresh CI"),
            Case(name: "capped", options: capped, says: "raise max_rounds"),
            Case(name: "refused", options: refused, says: "the budget changed"),
        ] {
            let log = Log()
            let store = try await makeStore(log, c.options)
            await store.fixFailedTests()
            let fix = try #require(store.ciFixShown(on: "t1"), "\(c.name)")
            #expect(fix.failed && fix.line.contains(c.says), "\(c.name): \(fix.line)")
            #expect(!log.all.contains { $0.hasPrefix("run") } && store.currentThread == "t1", "\(c.name)")
            #expect(store.busy == nil, "\(c.name)")
            #expect(store.feedDecision(for: try shown(store)).primary?.enabled == true, "\(c.name): it can be pressed again")
        }

        // A fix that cannot complete: its turn failed, or its check did, so nothing is pushed, and that is said.
        for (result, check) in [("failed", nil), ("succeeded", "failed")] as [(String, String?)] {
            var options = Options()
            (options.turnResult, options.check) = (result, check)
            let log = Log()
            let store = try await makeStore(log, options)
            await store.fixFailedTests()
            try await settle(store)
            let fix = try #require(store.ciFixShown(on: "t2"))
            #expect(fix.failed && fix.line.contains("nothing was pushed"), "\(fix.line)")
            #expect(!log.all.contains { $0.hasPrefix("ship") || $0.hasPrefix("accept") })
        }
    }

    @Test func refreshesCIAndPreservesMergeGate() async throws {
        let github = GitHub([
            Self.testFailed, Self.status([("test", "pending"), ("lint", "pass")]),
            Self.status([("test", "fail"), ("lint", "pass")]), Self.status([("test", "pass"), ("lint", "pass")]),
        ])
        var options = Options()
        options.github = github
        let log = Log()
        let store = try await makeStore(log, options)
        #expect(try !shown(store).canMerge)
        await store.fixFailedTests()
        try await settle(store)

        // Read again after the push: the new run, pending, not the failed one; Merge waits for it.
        let pending = try shown(store)
        #expect(pending.id == "t2" && pending.ci?.isPending == true, "\(String(describing: pending.ci))")
        #expect(pending.ci?.failedTests.isEmpty == true && !pending.canMerge)
        var decision = store.feedDecision(for: pending)
        #expect(decision.primary?.kind != .fixTests)
        #expect(([decision.primary] + decision.more).first { $0?.kind == .merge }??.enabled == false)

        // CI failed again: still no Merge; the fix is offered again.
        await store.refreshPullRequestCI()
        let failed = try shown(store)
        #expect(!failed.canMerge && failed.ci?.failedTests == ["test"])
        decision = store.feedDecision(for: failed)
        #expect(decision.primary?.kind == .fixTests && decision.more.first { $0.kind == .merge }?.enabled == false)

        // Green: Merge is offered, and only offered; nothing merged by itself.
        await store.refreshPullRequestCI()
        #expect(try shown(store).canMerge)
        #expect(store.feedDecision(for: try shown(store)).primary?.kind == .merge)
        #expect(!log.all.contains { $0.hasPrefix("merge") })
    }

    @Test func guardsUnavailableAndDuplicateFixes() async throws {
        // No failed test: nothing offered, and a press does nothing.
        for checks in [[("test", "pass"), ("lint", "fail")], [("test", "pending")], [("build-test", "pass")]] {
            var options = Options()
            options.github = GitHub([Self.status(checks)])
            let log = Log()
            let store = try await makeStore(log, options)
            let decision = store.feedDecision(for: try shown(store))
            #expect(!(([decision.primary] + decision.more).contains { $0?.kind == .fixTests }), "\(checks)")
            await store.fixFailedTests()
            #expect(log.all == ["ci t1"] && store.ciFix == nil, "\(checks): \(log.all)")
        }
        #expect(PullRequestCI.unavailable("no gh").failedTests.isEmpty && PullRequestCI.checking.failedTests.isEmpty)

        // Pressed again while the first is going: one fix, and the button says it is going.
        let gate = Gate()
        var options = Options()
        options.detailsGate = gate
        let log = Log()
        let store = try await makeStore(log, options)
        let first = Task { await store.fixFailedTests() }
        for _ in 0..<500 where log.all.last != "failedTests t1" { try await Task.sleep(for: .milliseconds(5)) }
        let going = store.feedDecision(for: try shown(store)).primary
        #expect(going?.kind == .fixTests && going?.enabled == false && going?.title == "Fixing tests…")
        await store.fixFailedTests()
        await store.perform(.fixTests)
        await gate.open()
        await first.value
        try await settle(store)
        #expect(log.all.filter { $0 == "failedTests t1" }.count == 1 && log.started.count == 1, "\(log.all)")
        #expect(log.all.filter { $0.hasPrefix("run") } == ["run t2"])
    }
}
