import Foundation
import WorkbenchCore

/// One button of the feed's decision card. The feed does not decide what a thread may do: `FeedActions.derive` reads the same rules the
/// step screens read (`canShip`, `canMerge`, the goal's `canApprove`, `RunModel.stoppable`) and only picks which one is the next press.
struct FeedAction: Equatable, Identifiable {
    enum Kind: String {
        case approveAndRun, run, stopTurn, stopAdvice, accept, ship, reviewPR, reviewAgain, merge, newGoal
        case discard, sendBack, openDiff, openWorktree, openHerdr, runAgain, refreshReview, editGoal, showFindings, refreshCI
    }

    var kind: Kind
    var title: String
    var help: String?
    var enabled = true
    var destructive = false

    var id: Kind { kind }
}

/// The next press and the rest. At most one primary, so a state never has two prominent buttons.
struct FeedDecision: Equatable {
    var primary: FeedAction?
    var more: [FeedAction] = []
}

/// What the decision depends on, gathered by the store so the function itself reads no state and a test can set each one.
struct FeedActionContext {
    var snapshot: ThreadSnapshot
    /// The goal screen's state; nil without a goal.
    var goalPill: GoalModel.Pill?
    var goalCanApprove = false
    /// A review is on screen (the latest turn awaits one), whether Accept may go, and whether it lists files to open.
    var reviewShown = false
    var reviewCanDecide = false
    var reviewHasFiles = false
    var busy = false
    var deciding = false
    var starting = false
    var runningHere = false
    var stopping = false
    var herdrFound = false
}

enum FeedActions {
    static func derive(_ c: FeedActionContext) -> FeedDecision {
        let s = c.snapshot
        guard s.state.decision == nil else { return decided(c) }
        var more: [FeedAction] = []
        func worktree() {
            more.append(FeedAction(kind: .openWorktree, title: "Open worktree", enabled: !c.busy))
            if c.herdrFound {
                more.append(
                    FeedAction(
                        kind: .openHerdr, title: "Open in Herdr",
                        help: "Herdr opens this worktree as a workspace and brings it forward", enabled: !c.busy))
            }
        }
        if let run = s.run, let stoppable = RunModel.stoppable(phase: run.phase, runningHere: c.runningHere) {
            worktree()
            let title = c.stopping ? "Stopping…" : (stoppable == .advice ? "Stop advice" : "Stop turn")
            return FeedDecision(
                primary: FeedAction(kind: stoppable == .advice ? .stopAdvice : .stopTurn, title: title, enabled: !c.stopping),
                more: more)
        }
        if c.reviewShown {
            let accept = FeedAction(
                kind: .accept, title: "Accept work", help: "Commits the work on its branch",
                enabled: c.reviewCanDecide && !c.deciding && !c.busy)
            more.append(FeedAction(kind: .sendBack, title: "Send back…", enabled: !c.busy))
            more.append(FeedAction(kind: .discard, title: "Discard…", enabled: !c.busy, destructive: true))
            more.append(
                FeedAction(
                    kind: .openDiff, title: "Open diff", help: "Each changed file against the base, in your editor",
                    enabled: !c.busy && c.reviewHasFiles))
            worktree()
            more.append(FeedAction(kind: .refreshReview, title: "Refresh", help: "Read the worktree again after editing it"))
            return FeedDecision(primary: accept, more: more)
        }
        if let run = s.run {
            worktree()
            let again = canRunAgain(run, runningHere: c.runningHere) ? FeedAction(kind: .runAgain, title: "Run again") : nil
            return FeedDecision(primary: again, more: more)
        }
        guard let pill = c.goalPill, pill != .approved || s.state.lastTurn == 0 else { return FeedDecision() }
        let runnable = c.goalCanApprove && !c.starting && !c.runningHere && !c.busy && s.state.lastTurn == 0
        more.append(FeedAction(kind: .editGoal, title: "Edit goal…", help: "Opens the goal's editor"))
        more.append(FeedAction(kind: .newGoal, title: "New goal…"))
        if c.herdrFound {
            more.append(FeedAction(kind: .openHerdr, title: "Open in Herdr", enabled: !c.busy))
        }
        let primary =
            pill == .approved
            ? FeedAction(kind: .run, title: "Run", enabled: runnable)
            : FeedAction(
                kind: .approveAndRun, title: "Approve and run", help: "Nothing runs until you approve", enabled: runnable)
        return FeedDecision(primary: primary, more: more)
    }

    /// A turn that did not succeed, or whose runner is gone, can be run again; one that succeeded goes to Review instead.
    static func canRunAgain(_ run: RunModel, runningHere: Bool) -> Bool {
        guard !runningHere else { return false }
        switch run.phase {
        case .orphaned: return true
        case .ended(let result, _): return result != "succeeded"
        default: return false
        }
    }

    private static func decided(_ c: FeedActionContext) -> FeedDecision {
        let s = c.snapshot
        let newGoal = FeedAction(kind: .newGoal, title: "New goal…")
        var more: [FeedAction] = []
        if s.canShip {
            more.append(newGoal)
            return FeedDecision(
                primary: FeedAction(
                    kind: .ship, title: "Ship", help: "Pushes the branch and opens or updates its pull request",
                    enabled: !c.busy && !c.deciding),
                more: more)
        }
        guard s.watchesPullRequest else { return FeedDecision(primary: newGoal) }
        let review = FeedAction(
            kind: s.state.review.prReview == nil ? .reviewPR : .reviewAgain,
            title: s.state.review.prReview == nil ? "Review PR" : "Review again",
            help: "Codex reads the pull request, read-only, and says what it found", enabled: !c.busy)
        let merge = FeedAction(
            kind: .merge, title: "Merge…", help: s.ci?.mergeBlocker ?? "Squash-merges the pull request on GitHub",
            enabled: s.canMerge && !c.busy && !c.deciding)
        if s.state.review.prReview != nil {
            more.append(FeedAction(kind: .showFindings, title: "Show findings"))
        }
        if s.ci != nil { more.append(FeedAction(kind: .refreshCI, title: "Refresh CI")) }
        more.append(newGoal)
        // Merge is the next press once GitHub says it can go; until then the review is.
        if s.canMerge { return FeedDecision(primary: merge, more: [review] + more) }
        return FeedDecision(primary: review, more: [merge] + more)
    }
}
