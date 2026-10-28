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

    /// An update of an open pull request whose text the proposal was made from.
    private struct Updating {
        var fx: RunnerFixture
        var gh: FakeGH
        var thread: UpdateThread
        var plan: ShipPlan
        var proposal: PRRefreshProposal
    }

    private func updating() async throws -> Updating {
        let fx = try await RunnerFixture()
        let thread = try await acceptedUpdateThread(fx)
        let gh = try FakeGH(in: fx)
        let head = try await shipOut(["rev-parse", "HEAD"], thread.worktree, fx)
        let item: [String: Any] = [
            "number": 12, "url": "https://github.com/o/r/pull/12", "headRefName": "feature/pr", "baseRefName": "main",
            "headRefOid": head, "title": "old title", "body": "old body",
        ]
        try gh.put("list", String(decoding: try JSONSerialization.data(withJSONObject: [item]), as: UTF8.self))
        let plan = try await fx.service.shipPreflight(id: thread.id, gh: gh.runner)
        let proposal = PRRefreshProposal(
            number: 12, current: PRText(title: "old title", body: "old body"),
            updated: PRText(title: "new title", body: "new body"), titleChanged: true, changes: [])
        return Updating(fx: fx, gh: gh, thread: thread, plan: plan, proposal: proposal)
    }

    @Test func anUpdateRecordsTheOpenPullRequestAndAppliesTheApprovedRefreshInOrder() async throws {
        let u = try await updating()
        let steps = Steps()
        let outcome = try await u.fx.service.publishShip(
            id: u.thread.id, gh: u.gh.runner, plan: u.plan, description: nil, refresh: u.proposal,
            progress: { steps.add($0) })
        #expect(steps.all == ["pushed", "opened", "refreshed", "screenshots", "cleaned"])
        #expect(outcome.pr.outcome == .existing && outcome.refreshApplied && outcome.refreshFailure == nil)
        #expect(u.gh.count("pr create") == 0 && u.gh.count("pr edit") == 1)
        #expect(u.gh.read("edit_title")?.trimmingCharacters(in: .whitespacesAndNewlines) == "new title")
    }

    @Test func aRejectedEditIsReturnedWithGhsReasonAndTheRestStillRuns() async throws {
        let u = try await updating()
        try u.gh.put("edit_fail", "GraphQL: not allowed\n")
        let steps = Steps()
        let outcome = try await u.fx.service.publishShip(
            id: u.thread.id, gh: u.gh.runner, plan: u.plan, description: nil, refresh: u.proposal,
            progress: { steps.add($0) })
        guard case .ghEditFailed(let why)? = outcome.refreshFailure else {
            Issue.record("expected ghEditFailed, got \(String(describing: outcome.refreshFailure))")
            return
        }
        #expect(why.contains("not allowed") && !outcome.refreshApplied && u.gh.count("pr edit") == 1)
        #expect(steps.all == ["pushed", "opened", "screenshots", "cleaned"])
    }

    @Test func aPullRequestThatCannotBeOpenedThrowsItsErrorAfterThePushAndNothingFollows() async throws {
        let r = try await ready()
        try r.gh.put("fail", "GraphQL: could not create\n")
        let steps = Steps()
        do {
            _ = try await r.fx.service.publishShip(
                id: r.id, gh: r.gh.runner, plan: r.plan, description: nil, progress: { steps.add($0) })
            Issue.record("expected the open to fail")
        } catch let error as ShipError {
            guard case .ghFailed = error else {
                Issue.record("got \(error)")
                return
            }
        }
        #expect(steps.all == ["pushed"] && FileManager.default.fileExists(atPath: r.plan.worktree.path))
    }

    @Test(arguments: [(true, false), (false, true)])
    func eachOptionAloneDoesOnlyItsOwnThing(keep: Bool, skip: Bool) async throws {
        let r = try await ready()
        let steps = Steps()
        _ = try await r.fx.service.publishShip(
            id: r.id, gh: r.gh.runner, plan: r.plan, description: nil,
            options: ShipPublishOptions(keepWorktree: keep, skipScreenshots: skip), progress: { steps.add($0) })
        #expect(steps.all == (keep ? ["pushed", "opened", "screenshots"] : ["pushed", "opened", "cleaned"]))
    }
}
