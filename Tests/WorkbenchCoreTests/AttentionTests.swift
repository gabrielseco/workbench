import Testing

@testable import WorkbenchCore

@Suite struct AttentionTests {
    private func attention(
        _ story: SpineStory, approval: ApprovalState? = .approved, checks: PRChecksSummary? = nil,
        hand: [String] = [], outcome: PullRequestOutcome = .open, currentHead: String? = nil
    ) -> Attention {
        let spine = ThreadSpine.derive(
            state: story.state, approval: approval, outcome: outcome, checks: checks, currentHead: currentHead)
        return Attention.derive(
            spine: spine, state: story.state, checks: checks, handChecks: hand, outcome: outcome, currentHead: currentHead)
    }

    private func reasonOf(_ attention: Attention) -> AttentionReason? {
        if case .needsYou(let reason) = attention { reason } else { nil }
    }

    private func shipped() -> SpineStory {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("accepted")
        story.ship()
        return story
    }

    private let green = PRChecksSummary(checks: [PRCheck(name: "linux", bucket: "pass")])

    @Test func aDraftGoalIsNeverAmber() {
        var story = SpineStory()
        story.add(.threadCreated)
        #expect(attention(story, approval: .draft) == .none)
    }

    @Test func aRunningTurnOrCheckIsWorkingNotAmber() {
        var story = SpineStory()
        story.approve()
        story.openTurn(1)
        #expect(attention(story) == .working)
        var checking = SpineStory()
        checking.approve()
        checking.turn(1)
        checking.add(.checkStarted, turn: 1, ["command": "x"])
        #expect(attention(checking) == .working)
    }

    @Test(arguments: ["succeeded", "failed", "stopped", "timed_out", "over_budget", "interrupted"])
    func aTurnThatEndedWithAnyResultNeedsYou(result: String) throws {
        var story = SpineStory()
        story.approve()
        story.turn(1, result: result)
        let reason = try #require(reasonOf(attention(story)))
        #expect(reason.text == "Review · turn 1 done" && reason.since == 3 && reason.commit == nil)
    }

    @Test func aCriterionOnlyAPersonCanCheckIsNamed() throws {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        let reason = try #require(reasonOf(attention(story, hand: ["C3"])))
        #expect(reason.text == "C3 by hand")
    }

    @Test func aSendBackIsWorkNotARequest() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.add(.threadNote, ["text": "again"])
        #expect(attention(story) == .none)
    }

    @Test func aFindingNeedsYouAtTheRoundsSeq() throws {
        var story = shipped()
        story.prRound(1, verdict: "fix")
        let reason = try #require(reasonOf(attention(story)))
        #expect(reason.text == "Findings open" && reason.since == story.events.count)
    }

    @Test func aFailedRoundNeedsYouAndARunningOneDoesNot() throws {
        var story = shipped()
        story.prRound(1, verdict: nil, reason: "at capacity")
        let reason = try #require(reasonOf(attention(story)))
        #expect(reason.text.hasPrefix("Review round 1 failed") && reason.text.contains("at capacity"))
        var running = shipped()
        running.add(.prReviewStarted, ["round": 1, "pr": 7, "head_sha": "abc123"])
        #expect(attention(running) == .working)
    }

    @Test func aCleanRoundIsReadyToMergeOnlyWhenCIIsKnownGreen() throws {
        var story = shipped()
        story.prRound(1, verdict: "clean")
        #expect(attention(story) == .none, "CI not checked: no claim")
        #expect(attention(story, checks: PRChecksSummary(checks: [PRCheck(name: "l", bucket: "pending")])) == .none)
        let reason = try #require(reasonOf(attention(story, checks: green)))
        #expect(reason.text == "Ready to merge" && reason.commit == "abc123")
    }

    @Test func aFailedCheckNeedsYouWithTheCommitAndNeedsChecksToSay() throws {
        var story = shipped()
        story.prRound(1, verdict: "clean")
        let red = PRChecksSummary(checks: [PRCheck(name: "unit tests", bucket: "fail")])
        let reason = try #require(reasonOf(attention(story, checks: red)))
        #expect(reason.text == "CI failed: unit tests" && reason.commit == "abc123")
        #expect(attention(story) == .none, "no CI row without a checks summary")
    }

    @Test func ciThatIsStillRunningIsNeverAmber() {
        let story = shipped()
        #expect(attention(story, checks: PRChecksSummary(checks: [PRCheck(name: "l", bucket: "pending")])) == .none)
    }

    @Test func aMergedPullRequestWaitingForCleanIsHousekeeping() {
        var story = shipped()
        story.prRound(1, verdict: "clean")
        #expect(attention(story, checks: green, outcome: .merged) == .none)
    }

    @Test func aDiscardedOrCleanedThreadIsQuiet() {
        var story = SpineStory()
        story.approve()
        story.turn(1)
        story.decide("discarded")
        #expect(attention(story) == .none)
        var cleaned = shipped()
        cleaned.add(.branchRemoved, ["reason": "merged"])
        #expect(attention(cleaned, checks: green) == .none)
    }

    @Test func aRunningVerifierOrJudgeIsWorkingNotAmber() {
        var verifying = SpineStory()
        verifying.approve()
        verifying.turn(1)
        verifying.verifier(open: true)
        #expect(attention(verifying) == .working)
        var judging = SpineStory()
        judging.approve()
        judging.turn(1)
        judging.judge(open: true)
        #expect(attention(judging) == .working)
    }

    @Test func ciIsIdentifiedByTheCommitTheLatestRoundReviewed() throws {
        var story = shipped()
        story.prRound(1, verdict: "clean", head: "newer456")
        let ready = try #require(reasonOf(attention(story, checks: green)))
        #expect(ready.commit == "newer456", "the PR opened at abc123 and moved on")
        let red = PRChecksSummary(checks: [PRCheck(name: "linux", bucket: "fail")])
        #expect(try #require(reasonOf(attention(story, checks: red))).commit == "newer456")
    }

    @Test func aCleanReviewOfAnOlderCommitIsNotReadyToMerge() throws {
        var story = shipped()
        story.prRound(1, verdict: "clean", head: "old111")
        #expect(attention(story, checks: green, currentHead: "new222") == .none)
        let ready = try #require(reasonOf(attention(story, checks: green, currentHead: "old111")))
        #expect(ready.text == "Ready to merge" && ready.commit == "old111")
        let red = PRChecksSummary(checks: [PRCheck(name: "linux", bucket: "fail")])
        #expect(try #require(reasonOf(attention(story, checks: red, currentHead: "new222"))).commit == "new222")
    }

    @Test func aCleanedThreadWithAnOpenFindingIsQuiet() {
        var story = shipped()
        story.prRound(1, verdict: "fix")
        story.add(.branchRemoved, ["reason": "merged"])
        #expect(attention(story) == .none)
    }
}
