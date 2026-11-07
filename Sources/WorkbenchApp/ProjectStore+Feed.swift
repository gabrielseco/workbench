import Foundation

/// What the modals over the feed that the store has no other state for are showing. They stand at the window, so the rail and the
/// toolbar are behind them too, and a project switch closes them.
struct FeedModals {
    /// The review of the latest turn, with every criterion and where it stands.
    var reviewingDetails = false
    /// The merge question for the thread's pull request.
    var confirmingMerge = false
    /// The file whose diff is open over the review.
    var diffPath: String?
}

extension ProjectStore {
    /// What is on screen: on, and either a person has chosen or there is room beside the feed (a narrow window shows the default nowhere).
    var runSettingsShowing: Bool { runSettingsOn && (runSettingsChosen || runSettingsFits) }

    /// Whether the thread's feed is what the window shows: the modals that belong to it are not up over another screen.
    var showsFeed: Bool {
        guard project != nil, !newThread, mode != .tasks, case .thread = screen else { return false }
        return true
    }

    /// The modals that belong to the feed, as shown: none of them is up over another screen (the New goal screen, Tasks), where the feed
    /// they were opened from is gone. What was open is cleared when the feed leaves (`appModals`), so it is not there on coming back.
    var reviewOverFeed: Bool { showsFeed && feedModals.reviewingDetails }
    var mergeOverFeed: Bool { showsFeed && feedModals.confirmingMerge }
    var diffOverFeed: String? { showsFeed ? feedModals.diffPath : nil }
    var discardOverFeed: Bool { showsFeed && pendingDiscard != nil }
    var prReviewOverFeed: Bool { showsFeed && prReviewShown != nil }

    /// The Run settings are over the feed: a person asked for them and the window is too narrow to have them beside it.
    var runSettingsOverFeed: Bool { showsFeed && runSettingsOn && runSettingsChosen && !runSettingsFits }

    /// The header's button and View ▸ Run settings: closes what is shown, opens what is not, so the first press in a narrow window opens it.
    func toggleRunSettings() {
        setRunSettings(RunSettingsLayout.toggled(on: runSettingsOn, chosen: runSettingsChosen, fits: runSettingsFits))
    }

    /// Shows or hides the Run settings inspector, and remembers it.
    func setRunSettings(_ on: Bool) {
        runSettingsChosen = true
        guard on != runSettingsOn || !preferences.runSettingsChosen else { return }
        preferences.runSettings = on
        runSettingsOn = on
    }
}

extension ProjectStore {
    /// Whether the inspector may change the goal now: it is a draft that no turn has run, and no approval, run or other action is going.
    /// The core refuses an edit only for a decided thread or a live runner, so the rest is the window's to keep.
    func goalEditable(_ snapshot: ThreadSnapshot, goal: GoalModel) -> Bool {
        goal.editable && snapshot.state.lastTurn == 0 && !starting && !runningHere && busy == nil
    }

    /// The advice switch pressed: the goal's `auto_advance` is set, or cleared when the project already does what is asked.
    func toggleAdvice() async { await editGoal { $0.advice.toggled() } }

    /// Whether the feed's goal card is the editor now: there is a goal and it may be changed.
    func feedEditsGoal(_ snapshot: ThreadSnapshot) -> Bool {
        goal.map { goalEditable(snapshot, goal: $0) } ?? false
    }

    /// "Run in Herdr" is offered while the goal has not run and nothing has been decided: the Goal screen's own condition.
    func canRunGoalInHerdr(_ snapshot: ThreadSnapshot, goal: GoalModel) -> Bool {
        (goal.pill != .approved || snapshot.state.lastTurn == 0) && snapshot.state.decision == nil
    }

    /// Why the run buttons are off: the goal cannot be approved, an approval or a run is going, something else is working, or a turn has run.
    func goalRunDisabled(_ snapshot: ThreadSnapshot, goal: GoalModel) -> Bool {
        !goal.canApprove || starting || runningHere || busy != nil || snapshot.state.lastTurn > 0
    }
}

/// The feed's buttons call the actions the step screens call, and nothing else.
extension ProjectStore {
    /// What the decision card depends on, read from the store: the same state the step screens' buttons read.
    func feedContext(for snapshot: ThreadSnapshot) -> FeedActionContext {
        FeedActionContext(
            snapshot: snapshot, goalPill: goal?.pill, goalCanApprove: goal?.canApprove ?? false, reviewShown: review != nil,
            reviewCanDecide: review?.canDecide ?? false, reviewHasFiles: !(review?.files.isEmpty ?? true), busy: busy != nil,
            deciding: deciding, starting: starting, runningHere: runningHere, stopping: stopping, herdrFound: herdrFound,
            guidance: guidanceNote, grantsInFlight: grantsInFlight > 0)
    }

    func feedDecision(for snapshot: ThreadSnapshot) -> FeedDecision { FeedActions.derive(feedContext(for: snapshot)) }

    /// Does what the button says. Merge is confirmed by the view before it gets here; the review's details are the view's to open.
    func perform(_ kind: FeedAction.Kind) async {
        switch kind {
        case .approveAndRun, .run: await approveAndRun()
        case .stopTurn, .stopAdvice: await stopTurn()
        case .accept: await accept()
        case .ship: await ship()
        case .reviewPR, .reviewAgain: await reviewPullRequest()
        case .merge: await mergePullRequest()
        case .newGoal: beginNewGoal()
        case .discard: await prepareDiscard()
        case .sendGuidance: sendGuidance()
        case .openDiff: await openDiff()
        case .openWorktree: await openWorktree()
        case .openHerdr: await openInHerdr()
        case .runAgain: await runAgain()
        case .refreshReview: await refreshReview()
        case .showFindings: await showPRReview()
        case .refreshCI: await refreshPullRequestCI()
        case .openPR: openPullRequest()
        case .reviewDetails: break
        }
    }
}
