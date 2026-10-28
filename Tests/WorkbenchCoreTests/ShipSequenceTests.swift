import Foundation
import Testing

@testable import WorkbenchCore

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ step: ShipProgress) {
        let name: String =
            switch step {
            case .pushed: "pushed"
            case .opened: "opened"
            case .refreshed: "refreshed"
            case .screenshots: "screenshots"
            case .cleaned: "cleaned"
            }
        lock.withLock { names.append(name) }
    }
    var all: [String] { lock.withLock { names } }
}

@Suite(.processGate) struct ShipSequenceTests {
    private struct Ready {
        var fx: RunnerFixture
        var gh: FakeGH
        var id: String
        var plan: ShipPlan
        var origin: URL
    }

    private func ready(proof: [String: String]? = nil) async throws -> Ready {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        if let proof { try await recordVerifierProof(fx, id, proof) }
        let origin = try await addOrigin(fx)
        let plan = try await fx.service.shipPreflight(id: id, gh: gh.runner)
        return Ready(fx: fx, gh: gh, id: id, plan: plan, origin: origin)
    }

    @Test func pushesThenOpensThenLeavesTheWorktreeWhenNothingCouldBeLost() async throws {
        let r = try await ready()
        let (fx, gh, id, plan) = (r.fx, r.gh, r.id, r.plan)
        let steps = Steps()
        let outcome = try await fx.service.publishShip(
            id: id, gh: gh.runner, plan: plan, description: nil, progress: { steps.add($0) })
        #expect(steps.all == ["pushed", "opened", "screenshots", "cleaned"])
        #expect(outcome.pr.number == 12 && outcome.refreshFailure == nil && !outcome.refreshApplied)
        guard case .removed? = outcome.cleanup else {
            Issue.record("expected the worktree removed, got \(String(describing: outcome.cleanup))")
            return
        }
        #expect(try fx.events(id).contains { $0.kind == .prOpened })
    }

    @Test func skippingScreenshotsRunsNoneAndKeepingTheWorktreeCleansNothing() async throws {
        let r = try await ready()
        let (fx, gh, id, plan) = (r.fx, r.gh, r.id, r.plan)
        let steps = Steps()
        let outcome = try await fx.service.publishShip(
            id: id, gh: gh.runner, plan: plan, description: nil,
            options: ShipPublishOptions(keepWorktree: true, skipScreenshots: true), progress: { steps.add($0) })
        #expect(steps.all == ["pushed", "opened"] && outcome.screenshots == nil && outcome.cleanup == nil)
        #expect(FileManager.default.fileExists(atPath: plan.worktree.path))
    }

    @Test func screenshotsThatWereNotAttachedKeepTheWorktreeForARetry() async throws {
        let r = try await ready(proof: ["home.png": "pixels"])
        let (fx, gh, id, plan) = (r.fx, r.gh, r.id, r.plan)
        let steps = Steps()
        let outcome = try await fx.service.publishShip(
            id: id, gh: gh.runner, plan: plan, description: nil, screenshotTool: nil, progress: { steps.add($0) })
        guard case .skipped? = outcome.screenshots else {
            Issue.record("expected skipped, got \(String(describing: outcome.screenshots))")
            return
        }
        #expect(steps.all == ["pushed", "opened", "screenshots"] && outcome.cleanup == nil)
        #expect(FileManager.default.fileExists(atPath: plan.worktree.path))
    }

    @Test func aPushThatFailsStopsBeforeThePullRequestIsOpened() async throws {
        let r = try await ready()
        let (fx, gh, id, plan) = (r.fx, r.gh, r.id, r.plan)
        let origin = r.origin
        // The remote is gone, so the push is rejected.
        try FileManager.default.removeItem(at: origin)
        let steps = Steps()
        do {
            _ = try await fx.service.publishShip(
                id: id, gh: gh.runner, plan: plan, description: nil, progress: { steps.add($0) })
            Issue.record("expected the push to fail")
        } catch is ShipError {}
        #expect(steps.all.isEmpty && gh.count("pr create") == 0)
        #expect(try !fx.events(id).contains { $0.kind == .prOpened })
    }

    @Test func aPlanThatChangedSinceItWasShownIsRefusedBeforeAnythingIsPushed() async throws {
        let r = try await ready()
        let (fx, gh, id, plan) = (r.fx, r.gh, r.id, r.plan)
        var other = plan
        other.head = "0000000000000000000000000000000000000000"
        do {
            _ = try await fx.service.publishShip(id: id, gh: gh.runner, plan: other, description: nil)
            Issue.record("expected changedSinceShown")
        } catch let error as ShipError {
            #expect(error == .changedSinceShown)
        }
        #expect(gh.count("pr create") == 0)
    }

    @Test func aRefreshThatFailsIsReturnedAndDoesNotStopTheRest() async throws {
        let r = try await ready()
        let (fx, gh, id, plan) = (r.fx, r.gh, r.id, r.plan)
        try gh.put("edit_fail", "edit failed")
        let proposal = PRRefreshProposal(
            number: 12, current: PRText(title: "old", body: "old"), updated: PRText(title: "new", body: "new"),
            titleChanged: true, changes: [])
        let steps = Steps()
        let outcome = try await fx.service.publishShip(
            id: id, gh: gh.runner, plan: plan, description: nil, refresh: proposal, progress: { steps.add($0) })
        #expect(outcome.refreshFailure != nil && !outcome.refreshApplied)
        #expect(steps.all == ["pushed", "opened", "screenshots", "cleaned"])
    }
}
