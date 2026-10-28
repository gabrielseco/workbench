import Testing

@testable import WorkbenchCore

@Suite struct ThreadSpineTests {
    private func marks(
        _ story: SpineStory, approval: ApprovalState? = .approved, outcome: PullRequestOutcome = .open,
        checks: PRChecksSummary? = nil
    ) -> [SpineMark] {
        ThreadSpine.derive(state: story.state, approval: approval, outcome: outcome, checks: checks).entries.map(\.mark)
    }

    @Test func theStepsAreSevenInFixedOrder() {
        let spine = ThreadSpine.derive(state: SpineStory().state)
        #expect(spine.entries.map(\.step) == SpineStep.allCases)
        #expect(spine.entries.count == 7)
    }

    @Test func aDraftGoalIsWritingAndEverythingElseWaits() {
        var story = SpineStory()
        story.add(.threadCreated)
        #expect(marks(story, approval: .draft) == [.current, .pending, .pending, .pending, .pending, .pending, .pending])
        #expect(ThreadSpine.derive(state: story.state, approval: .draft)[.goal].sublabel == "Writing")
    }

    @Test func aStaleApprovalIsNotApproved() {
        var story = SpineStory()
        story.add(.threadCreated)
        story.approve()
        let spine = ThreadSpine.derive(state: story.state, approval: .stale)
        #expect(spine[.goal].mark == .current && spine[.goal].sublabel == "Changed since approval")
    }

    @Test func anApprovedGoalWithNoTurnMakesRunCurrent() {
        var story = SpineStory()
        story.add(.threadCreated)
        story.approve()
        #expect(marks(story) == [.done, .current, .pending, .pending, .pending, .pending, .pending])
    }

    @Test func withoutAGoalFileTheLogsApprovalDecides() {
        var story = SpineStory()
        story.add(.threadCreated)
        #expect(ThreadSpine.derive(state: story.state, approval: nil)[.goal].mark == .current)
        story.approve()
        #expect(ThreadSpine.derive(state: story.state, approval: nil)[.goal].mark == .done)
    }

    @Test func anOpenTurnIsWorking() {
        var story = SpineStory()
        story.approve()
        story.openTurn(1)
        let spine = ThreadSpine.derive(state: story.state)
        #expect(spine[.run].mark == .current && spine[.run].sublabel == "Turn 1 · working")
        #expect(spine[.review].mark == .pending)
    }

    @Test func anEndedTurnWithNoDecisionNeedsYou() {
        var story = SpineStory()
        story.approve()
        story.turn(1, cost: 1.88)
        let spine = ThreadSpine.derive(state: story.state)
        #expect(spine[.run].mark == .done && spine[.run].sublabel == "Turn 1 · $1.88")
        #expect(spine[.review].mark == .needsYou && spine[.review].sublabel == "Needs you")
    }

    @Test func aFailedTurnShowsFailedAndStillNeedsYou() {
        var story = SpineStory()
        story.approve()
        story.turn(1, result: "timed_out")
        let spine = ThreadSpine.derive(state: story.state)
        #expect(spine[.run].mark == .failed && spine[.review].mark == .needsYou)
    }

    @Test func anUnreportedCostIsUnknownNotZero() {
        var story = SpineStory()
        story.approve()
        story.turn(1, cost: nil)
        #expect(ThreadSpine.derive(state: story.state)[.run].sublabel == "Turn 1 · cost unknown")
    }

    @Test func aSendBackMakesTheNextTurnCurrent() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.add(.threadNote, ["text": "fix the tests"])
        let spine = ThreadSpine.derive(state: story.state)
        #expect(spine[.run].mark == .current && spine[.run].sublabel == "Turn 2 · send-back")
        #expect(spine[.review].mark == .pending)
    }

    @Test func acceptedWithNoPullRequestMakesShipCurrent() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        #expect(marks(story) == [.done, .done, .done, .done, .current, .pending, .pending])
    }

    @Test func anOpenPullRequestWithNoRoundMakesPRReviewCurrent() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship()
        let spine = ThreadSpine.derive(state: story.state)
        #expect(spine[.ship].sublabel == "PR #7 open")
        #expect(spine[.prReview].mark == .current && spine[.prReview].sublabel == "No review yet")
    }

    @Test func aFindingNeedsYouAndACleanRoundIsDone() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship()
        story.prRound(1, verdict: "fix")
        #expect(ThreadSpine.derive(state: story.state)[.prReview].mark == .needsYou)
        story.prRound(2, verdict: "clean")
        let unchecked = ThreadSpine.derive(state: story.state)[.prReview]
        #expect(unchecked.mark == .current && unchecked.sublabel == "Clean · CI not checked", "done needs CI to pass")
    }

    @Test func aRoundThatOnlyStartedIsRunning() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship()
        story.add(.prReviewStarted, ["round": 1, "pr": 7, "head_sha": "abc123"])
        let entry = ThreadSpine.derive(state: story.state)[.prReview]
        #expect(entry.mark == .current && entry.sublabel == "Round 1 · running")
    }

    @Test func aFailedRoundIsFailed() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship()
        story.prRound(1, verdict: nil, reason: "at capacity")
        #expect(ThreadSpine.derive(state: story.state)[.prReview].mark == .failed)
    }

    @Test func aRoundForAnotherPullRequestDoesNotCount() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship(number: 8)
        story.prRound(1, verdict: "clean", number: 7)
        #expect(ThreadSpine.derive(state: story.state)[.prReview].sublabel == "No review yet")
    }

    @Test func ciDecidesAfterACleanRound() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship()
        story.prRound(1, verdict: "clean")
        let green = PRChecksSummary(checks: [PRCheck(name: "linux", bucket: "pass")])
        let red = PRChecksSummary(checks: [PRCheck(name: "linux", bucket: "fail"), PRCheck(name: "lint", bucket: "pass")])
        let running = PRChecksSummary(checks: [PRCheck(name: "linux", bucket: "pending")])
        #expect(ThreadSpine.derive(state: story.state, checks: green)[.prReview].sublabel == "Clean · CI passed")
        #expect(ThreadSpine.derive(state: story.state, checks: running)[.prReview].mark == .current)
        let failed = ThreadSpine.derive(state: story.state, checks: red)[.prReview]
        #expect(failed.mark == .needsYou && failed.sublabel == "CI failed: linux")
    }

    @Test func aMergedPullRequestMakesCleanCurrentUntilTheBranchIsRemoved() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship()
        #expect(ThreadSpine.derive(state: story.state, outcome: .merged)[.clean].mark == .current)
        #expect(ThreadSpine.derive(state: story.state, outcome: .merged)[.ship].sublabel == "PR #7 merged")
        story.add(.branchRemoved, ["reason": "merged"])
        let spine = ThreadSpine.derive(state: story.state, outcome: .merged)
        #expect(spine.entries.map(\.mark).last == .done && story.state.cleaned)
    }

    @Test func aDiscardedThreadEndsAtReview() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("discarded")
        #expect(marks(story) == [.done, .done, .done, .pending, .pending, .pending, .pending])
        #expect(ThreadSpine.derive(state: story.state)[.review].sublabel == "Discarded")
    }

    @Test func anAbandonedThreadWithNoTurnEndsAtReview() {
        var story = SpineStory()
        story.add(.threadCreated)
        story.decide("abandoned")
        let spine = ThreadSpine.derive(state: story.state, approval: .draft)
        #expect(spine[.review].mark == .done && spine[.review].sublabel == "Abandoned")
        #expect(spine[.run].mark == .pending)
    }

    @Test func aRunningVerifierOrJudgeIsWorkNotAReviewRequest() {
        for verifier in [true, false] {
            var story = SpineStory()
            story.approve()
            story.turn(1)
            if verifier { story.verifier(open: true) } else { story.judge(open: true) }
            let spine = ThreadSpine.derive(state: story.state)
            #expect(spine[.run].mark == .current && spine[.run].sublabel == "Turn 1 · " + (verifier ? "verifying" : "judging"))
            #expect(spine[.review].mark == .pending)
        }
    }

    @Test func aFinishedVerifierAndJudgeLeaveReviewToYou() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.verifier(open: false)
        story.judge(open: false)
        #expect(ThreadSpine.derive(state: story.state)[.review].mark == .needsYou)
    }
}
