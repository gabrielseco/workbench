import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var log: [String] { lock.withLock { items } }
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

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct ShipScreenTests {
    private nonisolated static let plan = ShipPlan(
        id: "t1", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1", remoteBranch: "workbench/t1",
        base: "origin/main", head: "abcdef1234567890", origin: "git@example.test:me/repo.git", remote: .absent,
        pullRequest: nil)
    private nonisolated static let preview = ShipPreview(
        plan: plan, description: nil, title: "feat: it", body: "## Summary\n\nIt.", note: nil)

    private func accepted() async throws -> AppFixture {
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "accepted")
        return fixture
    }

    private func store(
        _ recorder: Recorder, previewError: Error? = nil, shipError: Error? = nil, refreshFailure: ShipError? = nil
    ) async throws -> ProjectStore {
        let fixture = try await accepted()
        let actions = GoalActions(
            shipPreview: { _, _ in
                recorder.add("preview")
                if let previewError { throw previewError }
                return Self.preview
            },
            ship: { _, _, shown in
                recorder.add("ship \(shown == Self.preview)")
                if let shipError { throw shipError }
                var outcome = ShipOutcome(
                    push: ShipPushResult(plan: shown.plan, outcome: .pushed, ahead: nil),
                    pr: ShipPRResult(plan: shown.plan, url: "https://example.test/pull/7", number: 7, outcome: .created))
                outcome.refreshFailure = refreshFailure
                return outcome
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    /// One click publishes what the preview read, with no confirmation in between, and says where.
    @Test func shipImmediately() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        await store.ship()
        #expect(recorder.log == ["preview", "ship true"])
        #expect(store.actionError == nil && store.busy == nil && !store.deciding)
        #expect(store.notice == "Shipped as PR #7: https://example.test/pull/7")
    }

    @Test func aPreviewNoteIsShownWithTheShip() async throws {
        let fixture = try await accepted()
        var noted = Self.preview
        noted.note = "Could not describe the change."
        let shown = noted
        let actions = GoalActions(
            shipPreview: { _, _ in shown },
            ship: { _, _, preview in
                ShipOutcome(
                    push: ShipPushResult(plan: preview.plan, outcome: .pushed, ahead: nil),
                    pr: ShipPRResult(plan: preview.plan, url: "https://example.test/pull/7", number: 7, outcome: .created))
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        await store.ship()
        #expect(store.notice == "Shipped as PR #7: https://example.test/pull/7 Could not describe the change.")
    }

    @Test func aShipCoreRefusesIsShownAndPublishesNothing() async throws {
        let recorder = Recorder()
        let store = try await store(recorder, previewError: ShipError.notAccepted("nope"))
        await store.ship()
        #expect(store.actionError != nil && store.notice == nil && store.busy == nil)
        #expect(recorder.log == ["preview"])
    }

    @Test func aPushThatFailsSaysSoAndSetsNoNotice() async throws {
        let store = try await store(Recorder(), shipError: ShipError.notAccepted("rejected"))
        await store.ship()
        #expect(store.actionError != nil && store.notice == nil && !store.deciding)
    }

    @Test func aFailedTextRefreshIsAWarningOnAShipThatHappened() async throws {
        let store = try await store(Recorder(), refreshFailure: .notAccepted("gh said no"))
        await store.ship()
        #expect(store.notice != nil && store.actionError != nil)
    }

    @Test func aShipThatEndsAfterLeavingTheProjectDuringThePreviewPublishesNothing() async throws {
        let (gate, recorder) = (Gate(), Recorder())
        let fixture = try await accepted()
        let actions = GoalActions(
            shipPreview: { _, _ in
                await gate.wait()
                return Self.preview
            },
            ship: { _, _, _ in
                recorder.add("ship")
                throw ShipError.notAccepted("not reached")
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        let shipping = Task { await store.ship() }
        try await Task.sleep(for: .milliseconds(100))
        let other = try await AppFixture()
        keptFixtures.append(other)
        #expect(await store.open(other.root))
        await gate.open()
        _ = await shipping.value
        #expect(recorder.log.isEmpty && store.notice == nil && store.actionError == nil)
    }

    @Test func onlyAnAcceptedThreadWithoutAPullRequestCanBeShipped() async throws {
        func snapshot(_ build: (AppFixture) throws -> Void) async throws -> ThreadSnapshot? {
            let fixture = try await AppFixture(git: false)
            keptFixtures.append(fixture)
            try await fixture.addThread("t1", approved: true)
            try fixture.turn("t1", 1)
            try build(fixture)
            guard case .thread(let shown) = ProjectLoader.load(project: fixture.project).screen else { return nil }
            return shown
        }
        #expect(try await snapshot { _ in }?.canShip == false)
        #expect(try await snapshot { try $0.decide("t1", "accepted") }?.canShip == true)
        #expect(try await snapshot { try $0.decide("t1", "discarded") }?.canShip == false)
        #expect(
            try await snapshot {
                try $0.decide("t1", "accepted")
                try $0.ship("t1")
            }?.canShip == false)
    }

    @Test func textThatChangedSinceItWasShownIsRefused() throws {
        try ShipPreview.checkUnchanged(shown: ("t", "b"), now: ("t", "b"))
        #expect(throws: ShipPreview.TextChanged.self) { try ShipPreview.checkUnchanged(shown: ("t", "b"), now: ("t", "b2")) }
        #expect(throws: ShipPreview.TextChanged.self) { try ShipPreview.checkUnchanged(shown: ("t", "b"), now: ("t2", "b")) }
    }

    // MARK: CI and Merge

    private nonisolated static let head = String(repeating: "a", count: 40)

    private nonisolated static func status(_ state: PRState = .open, _ buckets: [String]?, error: String? = nil) -> PRStatus {
        let checks = buckets.map { list in
            PRChecksSummary(checks: list.enumerated().map { PRCheck(name: "c\($0.offset)", bucket: $0.element) })
        }
        return PRStatus(number: 7, state: state, head: head, checks: checks, checksError: error)
    }

    /// GitHub as the store sees it: what the next status read answers, and what a merge does.
    private final class GitHub: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Result<PRStatus, ShipError> = .success(ShipScreenTests.status(.open, ["pending"]))
        private var merge: Result<PRStatus, PRMergeError> = .success(ShipScreenTests.status(.merged, nil))
        private var merges: [String] = []
        func answer(_ next: Result<PRStatus, ShipError>) { lock.withLock { answer = next } }
        func merging(_ next: Result<PRStatus, PRMergeError>) { lock.withLock { merge = next } }
        var mergedHeads: [String] { lock.withLock { merges } }
        func read() throws -> PRStatus { try lock.withLock { answer }.get() }
        func doMerge(_ head: String) throws -> PRStatus {
            try lock.withLock {
                merges.append(head)
                return merge
            }
            .get()
        }
    }

    private func shippedStore(_ github: GitHub, verdict: String? = nil) async throws -> ProjectStore {
        let fixture = try await accepted()
        try fixture.ship("t1")
        if let verdict {
            try fixture.append(
                "t1", .prReviewFinished,
                data: ["ok": true, "verdict": .string(verdict), "round": 1, "pr": 7, "head_sha": .string(Self.head)])
        }
        let actions = GoalActions(
            pullRequestStatus: { _, _ in try github.read() }, mergePullRequest: { _, _, head in try github.doMerge(head) })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    private func shown(_ store: ProjectStore) throws -> ThreadSnapshot {
        guard case .thread(let snapshot) = store.screen else { throw GoalActions.Unset() }
        return snapshot
    }

    @Test func mergeAvailability() async throws {
        let github = GitHub()
        let store = try await shippedStore(github)
        let before = try shown(store)
        #expect(before.watchesPullRequest && !before.canMerge, "nothing read yet is not green")
        #expect(store.pullRequestCIIsDue)

        for (buckets, why) in [(["pending", "pass"], "running"), (["fail", "pass"], "failing"), ([], "no checks")] {
            github.answer(.success(Self.status(.open, buckets)))
            await store.refreshPullRequestCI()
            #expect(try !shown(store).canMerge, "\(why) is not green")
            #expect(try shown(store).ci?.mergeBlocker != nil)
        }
        github.answer(.success(Self.status(.open, ["pass", "skipping"])))
        await store.refreshPullRequestCI()
        #expect(try shown(store).canMerge && shown(store).ci?.summary == "CI green: 1 passed · 1 skipped")
        #expect(try shown(store).spine[.ship].sublabel == "PR #7 open")

        github.answer(.success(Self.status(.closed, nil)))
        await store.refreshPullRequestCI()
        #expect(try !shown(store).canMerge && !shown(store).watchesPullRequest, "a closed pull request is not merged")
        #expect(!store.pullRequestCIIsDue, "an ended pull request is not read again")
    }

    @Test func mergeOutcome() async throws {
        let github = GitHub()
        let store = try await shippedStore(github)
        github.answer(.success(Self.status(.open, ["pass"])))
        await store.refreshPullRequestCI()

        github.merging(.failure(.refused("base branch policy prohibits the merge")))
        await store.mergePullRequest()
        #expect(github.mergedHeads == [Self.head])
        #expect(store.actionError?.contains("policy prohibits") == true && store.notice == nil)
        #expect(try shown(store).ci?.status?.state == .open && shown(store).finishedText == "Shipped as PR #7.")

        github.merging(.failure(.notMerged(.open)))
        await store.mergePullRequest()
        #expect(store.actionError != nil && store.notice == nil)
        #expect(try shown(store).spine[.ship].sublabel == "PR #7 open", "a merge GitHub did not confirm is not shown merged")

        github.merging(.success(Self.status(.merged, nil)))
        await store.mergePullRequest()
        #expect(store.actionError == nil && store.notice == "Merged PR #7.")
        let merged = try shown(store)
        #expect(merged.finishedText == "Merged: PR #7." && merged.spine[.ship].sublabel == "PR #7 merged")
        #expect(merged.spine[.clean].mark == .current && !merged.canMerge && !merged.watchesPullRequest)
        // A reload from the log keeps what GitHub said: the log does not record the merge.
        await store.reload()
        #expect(try shown(store).finishedText == "Merged: PR #7.")
        #expect(github.mergedHeads.count == 3)
    }

    @Test func ciStatusUnavailable() async throws {
        let github = GitHub()
        let store = try await shippedStore(github)
        github.answer(.success(Self.status(.open, ["pass"])))
        await store.refreshPullRequestCI()
        #expect(try shown(store).canMerge)

        // A read that fails replaces the green it had: an old answer is never shown as the current one.
        github.answer(.failure(.ghFailed("HTTP 502")))
        await store.refreshPullRequestCI()
        var snapshot = try shown(store)
        #expect(!snapshot.canMerge && snapshot.ci?.unavailableReason?.contains("HTTP 502") == true)
        #expect(snapshot.ci?.summary.hasPrefix("CI status unavailable") == true)
        #expect(snapshot.spine[.prReview].sublabel != "Clean · CI passed")

        // Checks that cannot be read on a pull request whose state could be read are unavailable too.
        github.answer(.success(Self.status(.open, nil, error: "`gh pr checks` did not answer in 30s")))
        await store.refreshPullRequestCI()
        snapshot = try shown(store)
        #expect(!snapshot.canMerge && snapshot.ci?.unavailableReason != nil && snapshot.ci?.rows == [])

        await store.mergePullRequest()
        #expect(github.mergedHeads.isEmpty, "Merge does nothing while CI is unavailable")
    }

    @Test func aFailedReadClearsTheGreenFromTheSpineAndAttention() async throws {
        let github = GitHub()
        let store = try await shippedStore(github, verdict: "clean")
        github.answer(.success(Self.status(.open, ["pass"])))
        await store.refreshPullRequestCI()
        var snapshot = try shown(store)
        #expect(snapshot.spine[.prReview].sublabel == "Clean · CI passed")
        #expect(reason(snapshot) == "Ready to merge")

        github.answer(.failure(.ghFailed("HTTP 502")))
        await store.refreshPullRequestCI()
        snapshot = try shown(store)
        #expect(snapshot.spine[.prReview].sublabel == "Clean · CI not checked")
        #expect(reason(snapshot) == nil, "unknown CI is not ready to merge")
    }

    @Test func attentionFollowsWhatGitHubSaid() async throws {
        let github = GitHub()
        let store = try await shippedStore(github, verdict: "fix")
        #expect(try reason(shown(store)) == "Findings open")

        github.answer(.success(Self.status(.open, ["fail", "pass"])))
        await store.refreshPullRequestCI()
        #expect(try reason(shown(store)) == "CI failed: c0")

        github.answer(.success(Self.status(.open, ["pass"])))
        await store.refreshPullRequestCI()
        github.merging(.success(Self.status(.merged, nil)))
        await store.mergePullRequest()
        #expect(try shown(store).attention == .none, "a merged pull request asks nothing about its findings")
    }

    private func reason(_ snapshot: ThreadSnapshot) -> String? {
        if case .needsYou(let reason) = snapshot.attention { reason.text } else { nil }
    }

    @Test func ciProgressIsShownCheckByCheck() {
        let ci = PullRequestCI.known(Self.status(.open, ["pass", "pending", "fail", "skipping"]))
        #expect(ci.rows.map(\.kind) == [.passed, .running, .failed, .skipped])
        #expect(ci.summary == "CI running: 1 running · 1 failed · 1 passed · 1 skipped" && ci.isPending)
        #expect(PullRequestCI.checking.mergeBlocker != nil && !PullRequestCI.checking.canMerge)
    }

    @Test func aShipThatEndsAfterLeavingTheProjectSaysNothingInTheOtherOne() async throws {
        let gate = Gate()
        let fixture = try await accepted()
        let actions = GoalActions(
            shipPreview: { _, _ in Self.preview },
            ship: { _, _, shown in
                await gate.wait()
                return ShipOutcome(
                    push: ShipPushResult(plan: shown.plan, outcome: .pushed, ahead: nil),
                    pr: ShipPRResult(plan: shown.plan, url: "https://example.test/pull/7", number: 7, outcome: .created))
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        let shipping = Task { await store.ship() }
        try await Task.sleep(for: .milliseconds(100))
        let other = try await AppFixture()
        keptFixtures.append(other)
        #expect(await store.open(other.root))
        await gate.open()
        _ = await shipping.value
        #expect(store.notice == nil && store.actionError == nil)
    }
}
