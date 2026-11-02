import Foundation

/// The chat feed preview (P22): one switch, kept as an app preference, that swaps the thread screen for the feed.
extension ProjectStore {
    /// Turns the preview on or off, remembers it, and reads the thread again so the feed's items are there (or gone) at once.
    func setChatFeed(_ on: Bool) async {
        guard on != chatFeedOn else { return }
        preferences.chatFeed = on
        chatFeedOn = on
        await reload()
    }
}

extension ProjectStore {
    /// Shows or hides the Run settings inspector, and remembers it.
    func setRunSettings(_ on: Bool) {
        guard on != runSettingsOn else { return }
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
            deciding: deciding, starting: starting, runningHere: runningHere, stopping: stopping, herdrFound: herdrFound)
    }

    func feedDecision(for snapshot: ThreadSnapshot) -> FeedDecision { FeedActions.derive(feedContext(for: snapshot)) }

    /// Does what the button says. Merge is confirmed by the view before it gets here; the goal's editor and the review's details are
    /// the view's to open.
    func perform(_ kind: FeedAction.Kind) async {
        switch kind {
        case .approveAndRun, .run: await approveAndRun()
        case .stopTurn, .stopAdvice: await stopTurn()
        case .accept: await accept()
        case .ship: await ship()
        case .reviewPR, .reviewAgain: await reviewPullRequest()
        case .merge: await mergePullRequest()
        case .newGoal: namingGoal = true
        case .discard: await prepareDiscard()
        case .sendBack: (actionError, sendingBack) = (nil, true)
        case .openDiff: await openDiff()
        case .openWorktree: await openWorktree()
        case .openHerdr: await openInHerdr()
        case .runAgain: await runAgain()
        case .refreshReview: await refreshReview()
        case .showFindings: await showPRReview()
        case .refreshCI: await refreshPullRequestCI()
        case .editGoal, .reviewDetails: break
        }
    }
}
