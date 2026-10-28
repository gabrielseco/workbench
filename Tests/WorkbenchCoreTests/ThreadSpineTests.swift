import Testing

@testable import WorkbenchCore

/// A recorded thread log, one state at a time, the way the CLI writes it.
struct SpineStory {
    var events: [Event] = []

    mutating func add(_ kind: EventKind, turn: Int = 0, _ data: JSONValue = [:]) {
        let minute = String(format: "%02d", events.count % 60)
        events.append(Event(seq: events.count + 1, ts: "2026-10-28T14:\(minute):00.000Z", turn: turn, kind: kind, data: data))
    }

    var lastSeq: Int { events.count }
    var state: ThreadState { ThreadState.derive(from: events, id: "t") }

    static func draft() -> SpineStory {
        var story = SpineStory()
        story.add(.threadCreated, ["base": "main"])
        story.add(.goalSaved, ["status": "draft", "hash": .null])
        return story
    }

    static func approved() -> SpineStory {
        var story = draft()
        story.add(.goalApproved, ["hash": "h1", "budget_usd": 1.0])
        return story
    }

    mutating func startTurn(_ n: Int) { add(.turnStarted, turn: n, ["session_id": "s", "resume": .bool(n > 1)]) }

    mutating func endTurn(_ n: Int, result: String = "succeeded", cost: Double? = 0.5) {
        var data: [String: JSONValue] = ["result": .string(result)]
        if let cost { data["cost_usd"] = .double(cost) }
        add(.turnEnded, turn: n, .object(data))
    }

    static func ended(result: String = "succeeded") -> SpineStory {
        var story = approved()
        story.startTurn(1)
        story.endTurn(1, result: result)
        return story
    }

    static func accepted() -> SpineStory {
        var story = ended()
        story.add(.reviewDecision, ["decision": "accepted", "by": "user", "commit": "abc1234def"])
        return story
    }

    static func shipped() -> SpineStory {
        var story = accepted()
        story.add(
            .prOpened,
            ["url": "https://github.com/o/r/pull/482", "number": 482, "branch": "workbench/t", "base": "main",
             "head_sha": "feed0001"])
        return story
    }

    mutating func round(_ n: Int, verdict: String?, reason: String? = nil) {
        add(.prReviewStarted, ["round": .int(n), "pr": 482, "head_sha": "feed0001"])
        var data: [String: JSONValue] = [
            "round": .int(n), "pr": 482, "ok": .bool(verdict != nil), "head_sha": "feed0001",
            "verdict": verdict.map { .string($0) } ?? .null,
        ]
        if let reason { data["reason"] = .string(reason) }
        add(.prReviewFinished, .object(data))
    }
}

private func marks(_ spine: ThreadSpine) -> [ThreadSpine.Mark] { spine.entries.map(\.mark) }

@Suite struct ThreadSpineTests {
    @Test func spineAlwaysHasTheSevenStepsInOrder() {
        for story in [SpineStory(), .draft(), .ended(), .shipped()] {
            let spine = ThreadSpine.derive(state: story.state, goal: .draft)
            #expect(spine.entries.map(\.step) == ThreadSpine.Step.allCases)
            #expect(spine.entries.map(\.step.rawValue) == ["Goal", "Run", "Review", "Accept", "Ship", "PR review", "Clean"])
        }
    }

    @Test func spineDraftGoal() {
        let spine = ThreadSpine.derive(state: SpineStory.draft().state, goal: .draft)
        #expect(marks(spine) == [.current, .pending, .pending, .pending, .pending, .pending, .pending])
        #expect(spine.sublabel(.goal) == "Writing")
        let stale = ThreadSpine.derive(state: SpineStory.approved().state, goal: .stale)
        #expect(stale.mark(.goal) == .current && stale.sublabel(.goal) == "Changed since approval")
    }

    @Test func spineApprovedGoalWithNoTurn() {
        let spine = ThreadSpine.derive(state: SpineStory.approved().state, goal: .approved)
        #expect(marks(spine) == [.done, .current, .pending, .pending, .pending, .pending, .pending])
        #expect(spine.sublabel(.goal) == "Approved 14:02")
        #expect(spine.sublabel(.run) == "Ready to run")
    }

    @Test func spineOpenTurn() {
        var story = SpineStory.approved()
        story.startTurn(1)
        let spine = ThreadSpine.derive(state: story.state, goal: .approved)
        #expect(marks(spine) == [.done, .current, .pending, .pending, .pending, .pending, .pending])
        #expect(spine.sublabel(.run) == "Turn 1 · working")
        story.endTurn(1)
        story.add(.checkStarted, turn: 1, ["command": "scripts/check.sh"])
        #expect(ThreadSpine.derive(state: story.state, goal: .approved).sublabel(.run) == "Turn 1 · checking")
    }

    @Test func spineEndedTurnWithNoDecision() {
        let spine = ThreadSpine.derive(state: SpineStory.ended().state, goal: .approved)
        #expect(marks(spine) == [.done, .done, .needsYou, .pending, .pending, .pending, .pending])
        #expect(spine.sublabel(.run) == "Turn 1 · $0.50")
        #expect(spine.sublabel(.review) == "Needs you")

        var second = SpineStory.ended()
        second.add(.threadNote, ["text": "fix the edge case"])
        let sentBack = ThreadSpine.derive(state: second.state, goal: .approved)
        #expect(sentBack.mark(.run) == .current && sentBack.mark(.review) == .pending, "a send-back runs again")
        second.startTurn(2)
        second.endTurn(2, result: "interrupted", cost: nil)
        let interrupted = ThreadSpine.derive(state: second.state, goal: .approved)
        #expect(interrupted.sublabel(.run) == "Turn 2 · interrupted (send-back)")
        #expect(interrupted.mark(.review) == .needsYou, "an interrupted turn is reviewable")
    }

    @Test func spineAccepted() {
        let spine = ThreadSpine.derive(state: SpineStory.accepted().state, goal: .approved)
        #expect(marks(spine) == [.done, .done, .done, .done, .current, .pending, .pending])
        #expect(spine.sublabel(.accept) == "commit abc1234")
        #expect(spine.sublabel(.ship) == "Ready to ship")
    }

    @Test func spinePROpen() {
        let spine = ThreadSpine.derive(state: SpineStory.shipped().state, goal: .approved)
        #expect(marks(spine) == [.done, .done, .done, .done, .done, .current, .pending])
        #expect(spine.sublabel(.ship) == "PR #482 open")
        #expect(spine.sublabel(.prReview) == "Not reviewed yet")
    }

    @Test func spineReviewRoundWithAFinding() {
        var story = SpineStory.shipped()
        story.add(.prReviewStarted, ["round": 1, "pr": 482, "head_sha": "feed0001"])
        #expect(ThreadSpine.derive(state: story.state, goal: .approved).sublabel(.prReview) == "Round 1 · running")
        story.events.removeLast()
        story.round(1, verdict: "fix")
        let spine = ThreadSpine.derive(state: story.state, goal: .approved)
        #expect(marks(spine) == [.done, .done, .done, .done, .done, .needsYou, .pending])
        #expect(spine.sublabel(.prReview) == "Round 1 · findings open")

        story.round(2, verdict: nil, reason: "at capacity")
        let failed = ThreadSpine.derive(state: story.state, goal: .approved)
        #expect(failed.mark(.prReview) == .needsYou && failed.sublabel(.prReview) == "Round 2 failed: at capacity")
    }

    @Test func spineCleanRoundWithChecks() {
        var story = SpineStory.shipped()
        story.round(1, verdict: "clean")
        let noChecks = ThreadSpine.derive(state: story.state, goal: .approved)
        #expect(noChecks.mark(.prReview) == .current && noChecks.sublabel(.prReview) == "Round 1 clean")
        let green = PRChecksSummary(checks: [PRCheck(name: "linux", bucket: "pass")])
        let ready = ThreadSpine.derive(state: story.state, goal: .approved, remote: .init(state: .open, checks: green))
        #expect(ready.mark(.prReview) == .done && ready.sublabel(.prReview) == "Ready to merge")
        let merged = ThreadSpine.derive(state: story.state, goal: .approved, remote: .init(state: .merged))
        #expect(merged.mark(.prReview) == .done && merged.mark(.clean) == .current)
        #expect(merged.sublabel(.clean) == "Ready to clean")
    }

    @Test func spineMergedAndCleaned() {
        var story = SpineStory.shipped()
        story.round(1, verdict: "clean")
        story.add(.worktreeRemoved, ["reason": "shipped", "head_sha": "feed0001"])
        #expect(ThreadSpine.derive(state: story.state, goal: .approved).mark(.clean) == .pending, "removed at ship")
        story.add(.branchRemoved, ["reason": "merged", "head_sha": "feed0001"])
        let spine = ThreadSpine.derive(state: story.state, goal: .approved)
        #expect(marks(spine) == [.done, .done, .done, .done, .done, .done, .done])
        #expect(spine.sublabel(.prReview) == "Merged" && spine.sublabel(.clean) == "Branch removed")

        var closed = SpineStory.shipped()
        closed.add(.branchRemoved, ["reason": "closed", "head_sha": "feed0001"])
        let closedSpine = ThreadSpine.derive(state: closed.state, goal: .approved)
        #expect(closedSpine.mark(.prReview) == .failed && closedSpine.mark(.clean) == .done)
    }

    @Test func spineDiscarded() {
        var story = SpineStory.ended()
        story.add(.reviewDecision, ["decision": "discarded", "by": "user"])
        let spine = ThreadSpine.derive(state: story.state, goal: .approved)
        #expect(marks(spine) == [.done, .done, .failed, .pending, .pending, .pending, .pending])
        #expect(spine.sublabel(.review) == "Discarded")
    }

    @Test func spineAbandoned() {
        var story = SpineStory.approved()
        story.add(.reviewDecision, ["decision": "abandoned", "by": "user"])
        // The goal file was edited after the thread ended: it does not reopen the goal.
        let spine = ThreadSpine.derive(state: story.state, goal: .stale)
        #expect(marks(spine) == [.done, .pending, .failed, .pending, .pending, .pending, .pending])
        #expect(spine.sublabel(.review) == "Abandoned")
    }
}
