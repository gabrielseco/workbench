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

    @Test func preparingShowsWhatWouldBePublishedAndPublishesNothing() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        await store.prepareShip()
        #expect(store.pendingShip == Self.preview)
        #expect(recorder.log == ["preview"])
    }

    @Test func confirmingPublishesExactlyWhatWasShownAndSaysWhere() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        await store.prepareShip()
        await store.confirmShip()
        #expect(recorder.log == ["preview", "ship true"])
        #expect(store.pendingShip == nil && store.actionError == nil)
        #expect(store.notice == "Shipped as PR #7: https://example.test/pull/7")
    }

    @Test func cancellingPublishesNothing() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        await store.prepareShip()
        store.cancelShip()
        await store.confirmShip()
        #expect(store.pendingShip == nil && recorder.log == ["preview"])
    }

    @Test func aShipCoreRefusesIsShownAndLeavesNothingPending() async throws {
        let recorder = Recorder()
        let store = try await store(recorder, previewError: ShipError.notAccepted("nope"))
        await store.prepareShip()
        #expect(store.pendingShip == nil && store.actionError != nil)
        await store.confirmShip()
        #expect(recorder.log == ["preview"])
    }

    @Test func aPushThatFailsAfterConfirmingSaysSoAndSetsNoNotice() async throws {
        let store = try await store(Recorder(), shipError: ShipError.notAccepted("rejected"))
        await store.prepareShip()
        await store.confirmShip()
        #expect(store.actionError != nil && store.notice == nil && store.pendingShip == nil)
    }

    @Test func aFailedTextRefreshIsAWarningOnAShipThatHappened() async throws {
        let store = try await store(Recorder(), refreshFailure: .notAccepted("gh said no"))
        await store.prepareShip()
        await store.confirmShip()
        #expect(store.notice != nil && store.actionError != nil)
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
        await store.prepareShip()
        let shipping = Task { await store.confirmShip() }
        try await Task.sleep(for: .milliseconds(100))
        let other = try await AppFixture()
        keptFixtures.append(other)
        #expect(await store.open(other.root))
        await gate.open()
        await shipping.value
        #expect(store.notice == nil && store.actionError == nil)
    }
}
