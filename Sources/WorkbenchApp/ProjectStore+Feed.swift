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

    /// Does what the button says. Merge is confirmed by the view before it gets here, and the goal's editor is the view's to open.
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
        case .editGoal: break
        }
    }
}
