import Foundation

/// What `publishShip` leaves out or keeps.
public struct ShipPublishOptions: Sendable, Equatable {
    /// Keep the worktree even when nothing could be lost by removing it.
    public var keepWorktree = false
    /// Do not put the turn's screenshots in the pull request.
    public var skipScreenshots = false

    public init(keepWorktree: Bool = false, skipScreenshots: Bool = false) {
        self.keepWorktree = keepWorktree
        self.skipScreenshots = skipScreenshots
    }
}

/// One step of `publishShip`, reported as it finishes, so a caller can say it as it happens.
public enum ShipProgress: Sendable, Equatable {
    case pushed(ShipPushResult)
    case opened(ShipPRResult)
    case refreshed
    case screenshots(ShipScreenshots)
    case cleaned(ShipCleanup)
}

/// What `publishShip` did, for a caller that does not follow the progress.
public struct ShipOutcome: Sendable, Equatable {
    public var push: ShipPushResult
    public var pr: ShipPRResult
    public var refreshApplied = false
    /// Applying the approved text refresh failed. The pull request is open either way, so this is a note, not a stop.
    public var refreshFailure: ShipError?
    public var screenshots: ShipScreenshots?
    public var cleanup: ShipCleanup?
}

extension ThreadService {
    /// What happens after a person confirmed a ship, in the order and with the rules the CLI has always had: push the
    /// branch, open (or record) the pull request, apply the refresh the person approved, put the screenshots in, and remove
    /// the worktree when nothing could be lost. A push or open that fails throws its `ShipError` and nothing after it
    /// runs; a failed refresh, the screenshots and the cleanup never stop the ship, because the pull request is open.
    ///
    /// - Parameters:
    ///   - plan: the preflight the person confirmed; core refuses it if the target changed since.
    ///   - description: the model's description for a new pull request, nil for the goal-based body.
    ///   - refresh: the proposal to apply, only when the person approved it.
    ///   - screenshotTool: `pr-shots`, nil when it is not installed (the screenshots are then skipped with a note).
    public func publishShip(
        id: String, gh: GitRunner?, plan: ShipPlan, description: PRDescription?, refresh: PRRefreshProposal? = nil,
        screenshotTool: GitRunner? = nil, options: ShipPublishOptions = ShipPublishOptions(),
        progress: @Sendable (ShipProgress) -> Void = { _ in }
    ) async throws -> ShipOutcome {
        let pushed = try await shipPush(id: id, gh: gh, shown: plan)
        progress(.pushed(pushed))
        let pr = try await shipOpenPR(id: id, gh: gh, shown: plan, description: description)
        progress(.opened(pr))
        var outcome = ShipOutcome(push: pushed, pr: pr)

        if let refresh {
            do {
                try await applyPRRefresh(id: id, plan: plan, proposal: refresh, gh: gh)
                outcome.refreshApplied = true
                progress(.refreshed)
            } catch let error as ShipError { outcome.refreshFailure = error }
        }
        var attached = true
        if !options.skipScreenshots {
            let shots = await shipScreenshots(id: id, worktree: plan.worktree, number: pr.number, tool: screenshotTool)
            outcome.screenshots = shots
            progress(.screenshots(shots))
            if case .skipped = shots { attached = false }
        }
        // Kept when the screenshots did not go up, so `ship --screenshots` can try again.
        if !options.keepWorktree, attached {
            let cleaned = await cleanShipped(id: id, gh: gh)
            outcome.cleanup = cleaned
            progress(.cleaned(cleaned))
        }
        return outcome
    }
}
