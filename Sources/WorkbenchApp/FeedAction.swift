import Foundation
import WorkbenchCore

/// One button of the feed's decision card. The feed does not decide what a thread may do: `FeedActions.derive` reads the same rules the
/// step screens read (`canShip`, `canMerge`, the goal's `canApprove`, `RunModel.stoppable`) and only picks which one is the next press.
struct FeedAction: Equatable, Identifiable {
    enum Kind: String {
        case approveAndRun, run, stopTurn, stopAdvice, accept, ship, reviewPR, reviewAgain, merge, newGoal
        case discard, sendGuidance, openDiff, openWorktree, openHerdr, runAgain, refreshReview, reviewDetails
        case showFindings, refreshCI, openPR
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
    /// The one plain button beside the primary, for what a person does before pressing it (Review: see what changed).
    var secondary: FeedAction?
    var more: [FeedAction] = []
    /// Replaces the spine's line under the step when the button is not about what that line says (Merge, on the PR review step).
    var why: String?
    /// Replaces the spine step's title as the heading (a chat is on no step).
    var title: String?
    /// The guidance field is under the card: the work is in review and a turn can still be asked for.
    var takesGuidance = false
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
    /// What is typed in the guidance field, and whether a grant is still being saved (a send waits for it).
    var guidance = ""
    var grantsInFlight = false
}

enum FeedActions {
    static func derive(_ c: FeedActionContext) -> FeedDecision {
        let s = c.snapshot
        guard s.state.decision == nil else { return decided(c) }
        // A chat has no goal to approve and nothing to run: the chat screen draws its own composer, so this only names the step if a card is asked for.
        if s.state.isChat, s.approval == nil {
            let why = "No goal yet. The conversation is in the log; run workbench chat <id> to go on with it."
            return FeedDecision(primary: nil, why: why, title: "Chat")
        }
        var more: [FeedAction] = []
        func worktree(opens: Bool = true) {
            if opens {
                more.append(
                    FeedAction(
                        kind: .openWorktree, title: "Open worktree", help: "Opens the worktree in your editor", enabled: !c.busy))
            }
            if c.herdrFound {
                more.append(
                    FeedAction(
                        kind: .openHerdr, title: "Open in Herdr",
                        help: "Herdr opens this worktree as a workspace and brings it forward", enabled: !c.busy))
            }
        }
        if let run = s.run, let stoppable = RunModel.stoppable(phase: run.phase, runningHere: c.runningHere) {
            worktree(opens: false)
            let title = c.stopping ? "Stopping…" : (stoppable == .advice ? "Stop advice" : "Stop turn")
            // The files change while it works, so a diff is stale at once: open the worktree. Open diff is Review's.
            let open = FeedAction(
                kind: .openWorktree, title: "Open worktree", help: "Opens the worktree in your editor, where it is working",
                enabled: !c.busy && RunSettingsLayout.hasWorktree(s.state))
            return FeedDecision(
                primary: FeedAction(
                    kind: stoppable == .advice ? .stopAdvice : .stopTurn, title: title,
                    help: "Asks it to end; it still ends with a recorded stop", enabled: !c.stopping),
                secondary: open, more: more)
        }
        if c.reviewShown {
            let accept = FeedAction(
                kind: .accept, title: "Accept work", help: "Commits the work on its branch",
                enabled: c.reviewCanDecide && !c.deciding && !c.busy)
            let writing = !c.guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let send = FeedAction(
                kind: .sendGuidance, title: "Send to agent", help: "Starts the next turn with what you wrote",
                enabled: !c.busy && !c.starting && !c.grantsInFlight)
            more.append(
                FeedAction(
                    kind: .reviewDetails, title: "Review details…",
                    help: "Each criterion and how it was assessed, the check, the judge and the changed files"))
            more.append(
                FeedAction(
                    kind: .discard, title: "Discard…", help: "Shows what would be removed, and asks first", enabled: !c.busy,
                    destructive: true))
            let diff = FeedAction(
                kind: .openDiff, title: "Open diff", help: "Each changed file against the base, in your editor",
                enabled: !c.busy && c.reviewHasFiles)
            worktree()
            more.append(FeedAction(kind: .refreshReview, title: "Refresh", help: "Reads the worktree again after editing it"))
            // Writing turns the primary into the send; Accept stays beside it and Open diff goes in the menu.
            if writing {
                more.insert(diff, at: 0)
                return FeedDecision(primary: send, secondary: accept, more: more, title: "Accept the work", takesGuidance: true)
            }
            return FeedDecision(primary: accept, secondary: diff, more: more, title: "Accept the work", takesGuidance: true)
        }
        if let run = s.run {
            worktree()
            let again =
                canRunAgain(run, runningHere: c.runningHere)
                ? FeedAction(
                    kind: .runAgain, title: "Run again", help: "Records the unfinished turn as interrupted and goes on")
                : nil
            return FeedDecision(primary: again, more: more)
        }
        guard let pill = c.goalPill, pill != .approved || s.state.lastTurn == 0 else { return FeedDecision() }
        let runnable = c.goalCanApprove && !c.starting && !c.runningHere && !c.busy && s.state.lastTurn == 0
        more.append(FeedAction(kind: .newGoal, title: "New goal…", help: "Starts another goal"))
        if c.herdrFound {
            more.append(
                FeedAction(
                    kind: .openHerdr, title: "Open in Herdr", help: "Opens the project in Herdr, without starting anything",
                    enabled: !c.busy))
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
        let newGoal = FeedAction(kind: .newGoal, title: "New goal…", help: "Starts another goal")
        var more: [FeedAction] = []
        // The worktree is still there until the thread is discarded or cleaned, and a person may want to look at what they are shipping.
        if s.state.decision != "discarded", !s.state.cleaned {
            more.append(
                FeedAction(
                    kind: .openWorktree, title: "Open worktree", help: "Opens the worktree in your editor", enabled: !c.busy))
        }
        if c.herdrFound {
            more.append(
                FeedAction(
                    kind: .openHerdr, title: "Open in Herdr",
                    help: "Herdr opens this worktree, or the project when it is gone, and brings it forward", enabled: !c.busy))
        }
        if s.canShip {
            more.append(newGoal)
            return FeedDecision(
                primary: FeedAction(
                    kind: .ship, title: "Ship", help: "Pushes the branch and opens or updates its pull request",
                    enabled: !c.busy && !c.deciding),
                more: more)
        }
        guard s.watchesPullRequest else { return FeedDecision(primary: newGoal, more: more) }
        let review = FeedAction(
            kind: s.state.review.prReview == nil ? .reviewPR : .reviewAgain,
            title: s.state.review.prReview == nil ? "Review PR" : "Review again",
            help: "Codex reads the pull request, read-only, and says what it found", enabled: !c.busy)
        let merge = FeedAction(
            kind: .merge, title: "Merge", help: s.ci?.mergeBlocker ?? "Squash-merges the pull request on GitHub",
            enabled: s.canMerge && !c.busy && !c.deciding)
        if s.state.review.prReview != nil {
            more.append(FeedAction(kind: .showFindings, title: "Show findings", help: "Opens what the latest round found"))
        }
        if s.ci != nil {
            more.append(
                FeedAction(kind: .refreshCI, title: "Refresh CI", help: "Reads the pull request's checks from GitHub again"))
        }
        more.append(newGoal)
        // The pull request is where the review and the merge happen: one press from here, whatever the next step is.
        let open = FeedAction(kind: .openPR, title: "Open PR", help: "Opens the pull request on GitHub in your browser")
        // Merge is the next press once GitHub says it can go; until then the review is.
        if s.canMerge {
            return FeedDecision(
                primary: merge, secondary: open, more: [review] + more, why: "CI is green: the pull request can be merged")
        }
        // A clean review leaves nothing but the merge: it stays the button, disabled and saying what it waits for.
        if reviewIsClean(s), s.ci?.ended != true {
            return FeedDecision(
                primary: merge, secondary: open, more: [review] + more, why: "Review is clean. " + waiting(s))
        }
        return FeedDecision(primary: review, secondary: open, more: [merge] + more)
    }

    /// The latest round is finished, found nothing, and is of this pull request at the commit GitHub shows now.
    static func reviewIsClean(_ s: ThreadSnapshot) -> Bool {
        guard let round = s.state.review.prReview, round.verdict == "clean", !round.isOpen,
            round.pr == nil || round.pr == s.state.pullRequest?.number
        else { return false }
        // Once GitHub says which commit it is at, a review that did not record its commit cannot be said to cover it.
        if let head = s.ci?.status?.head, round.headSHA != head { return false }
        return true
    }

    /// What the merge waits for, in words.
    private static func waiting(_ s: ThreadSnapshot) -> String {
        s.ci?.mergeBlocker ?? "CI is not known."
    }
}
