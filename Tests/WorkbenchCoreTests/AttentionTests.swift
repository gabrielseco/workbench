import Testing

@testable import WorkbenchCore

private let green = PRChecksSummary(checks: [PRCheck(name: "linux", bucket: "pass"), PRCheck(name: "lint", bucket: "pass")])
private let red = PRChecksSummary(checks: [PRCheck(name: "unit tests", bucket: "fail"), PRCheck(name: "lint", bucket: "pass")])
private let running = PRChecksSummary(checks: [PRCheck(name: "linux", bucket: "pending")])

@Suite struct AttentionTests {
    @Test func attentionTurnEndedWithNoDecision() {
        for result in ["succeeded", "failed", "stopped", "timed_out", "over_budget", "interrupted"] {
            let story = SpineStory.ended(result: result)
            let label = result == "succeeded" ? "done" : result
            #expect(
                Attention.derive(state: story.state)
                    == .needsYou(reason: "Review · turn 1 \(label)", since: .seq(story.lastSeq)), "\(result)")
        }
    }

    @Test func attentionNamesCriteriaForAPerson() {
        var story = SpineStory.ended()
        story.add(.judgeStarted, turn: 1)
        #expect(Attention.derive(state: story.state) == .working, "a running judge is never amber")
        story.add(
            .judgeRan, turn: 1,
            ["ok": true, "criteria": [["id": "c2", "met": true], ["id": "c3", "met": false]], "concerns": []])
        let ended = story.state.lastTurnEndedSeq ?? 0
        #expect(
            Attention.derive(state: story.state, byHand: ["c1"])
                == .needsYou(reason: "Review · turn 1 done · c1, c3 by hand", since: .seq(ended)))
    }

    @Test func attentionNeverForARunningTurnEvenWithADenial() {
        var story = SpineStory.approved()
        story.startTurn(1)
        story.add(.agentActivity, turn: 1, ["type": "tool_denied", "tool": "Bash"])
        #expect(Attention.derive(state: story.state) == .working)
        story.endTurn(1)
        story.add(.checkStarted, turn: 1, ["command": "scripts/check.sh"])
        #expect(Attention.derive(state: story.state) == .working, "an open check is working")
    }

    @Test func attentionNeverForADraftGoalOrAnApprovedOneWithNoTurn() {
        #expect(Attention.derive(state: SpineStory.draft().state) == .none)
        #expect(Attention.derive(state: SpineStory.approved().state) == .none)
    }

    @Test func attentionNeverForAMergedPRAwaitingClean() {
        var story = SpineStory.shipped()
        story.round(1, verdict: "clean")
        #expect(Attention.derive(state: story.state, remote: .init(state: .merged, checks: green)) == .none)
        #expect(Attention.derive(state: story.state, remote: .init(state: .closed, checks: red)) == .none)
        story.add(.branchRemoved, ["reason": "merged", "head_sha": "feed0001"])
        #expect(Attention.derive(state: story.state, remote: .init(state: .open, checks: red)) == .none)
    }

    @Test func attentionNoneOnceDiscardedOrAbandoned() {
        for decision in ["discarded", "abandoned"] {
            var story = SpineStory.ended()
            story.add(.reviewDecision, ["decision": .string(decision), "by": "user"])
            #expect(Attention.derive(state: story.state) == .none)
        }
        #expect(Attention.derive(state: SpineStory.accepted().state) == .none, "shipping is not a request")
    }

    @Test func attentionPRReviewRounds() {
        var story = SpineStory.shipped()
        story.add(.prReviewStarted, ["round": 1, "pr": 482, "head_sha": "feed0001"])
        #expect(Attention.derive(state: story.state) == .working)
        story.events.removeLast()
        story.round(1, verdict: "fix")
        #expect(
            Attention.derive(state: story.state)
                == .needsYou(reason: "Review round 1: findings open", since: .seq(story.lastSeq)))
        story.round(2, verdict: nil, reason: "at capacity")
        #expect(
            Attention.derive(state: story.state)
                == .needsYou(reason: "Review round 2 failed: at capacity", since: .seq(story.lastSeq)))
    }

    @Test func ciRowsNeedAChecksSummary() {
        var story = SpineStory.shipped()
        story.round(1, verdict: "clean")
        #expect(Attention.derive(state: story.state) == .none, "no checks passed in: no CI reason")
        #expect(Attention.derive(state: story.state, remote: .init(state: .open)) == .none)
        #expect(
            Attention.derive(state: story.state, remote: .init(state: .open, checks: green))
                == .needsYou(reason: "Ready to merge", since: .commit("feed0001")))
        #expect(Attention.derive(state: story.state, remote: .init(state: .open, checks: running)) == .none)
    }

    @Test func ciFailedIsYoursWithOrWithoutARound() {
        let story = SpineStory.shipped()
        let expected = Attention.needsYou(reason: "CI failed: unit tests", since: .commit("feed0001"))
        #expect(Attention.derive(state: story.state, remote: .init(state: .open, checks: red)) == expected)
        #expect(Attention.derive(state: story.state, remote: .init(state: .open, checks: green)) == .none, "not reviewed")
        var reviewed = story
        reviewed.round(1, verdict: "clean")
        #expect(Attention.derive(state: reviewed.state, remote: .init(state: .open, checks: red)) == expected)
        #expect(ThreadSpine.derive(state: story.state, goal: .approved).mark(.prReview) == .current)
        #expect(
            ThreadSpine.derive(state: story.state, goal: .approved, remote: .init(state: .open, checks: red))
                .sublabel(.prReview) == "CI failed: unit tests")
    }

    @Test func aFixPushIsANewCIReason() {
        var story = SpineStory.shipped()
        story.round(1, verdict: "clean")
        let first = Attention.derive(state: story.state, remote: .init(state: .open, checks: red, headSHA: "aaa"))
        let second = Attention.derive(state: story.state, remote: .init(state: .open, checks: red, headSHA: "bbb"))
        #expect(first == .needsYou(reason: "CI failed: unit tests", since: .commit("aaa")))
        #expect(second == .needsYou(reason: "CI failed: unit tests", since: .commit("bbb")))
    }
}
