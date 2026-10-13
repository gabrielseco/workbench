import Testing

@testable import WorkbenchCore

/// Builds events with the next `seq`, so a test reads as the story of a thread.
private struct Story {
    var events: [Event] = []

    mutating func add(_ kind: EventKind, turn: Int = 0, _ data: JSONValue = [:]) {
        events.append(
            Event(seq: events.count + 1, ts: "2026-10-13T10:00:00.000Z", turn: turn, kind: kind, data: data))
    }

    mutating func turn(_ n: Int, result: String = "succeeded", cost: Double? = nil, denied: [String] = []) {
        add(.turnStarted, turn: n, ["session_id": "s1", "resume": .bool(n > 1)])
        let denials = JSONValue.array(denied.map { ["tool_name": .string($0)] })
        add(.claude, turn: n, ["type": "result", "permission_denials": denials])
        var ended: [String: JSONValue] = ["result": .string(result), "permission_denials": .int(denied.count)]
        if let cost { ended["cost_usd"] = .double(cost) }
        add(.turnEnded, turn: n, .object(ended))
    }

    mutating func check(_ n: Int, result: String = "passed", exit: Int? = 0) {
        add(.checkStarted, turn: n, ["command": "scripts/check.sh"])
        add(
            .checkRan, turn: n,
            [
                "result": .string(result), "exit_code": exit.map { .int($0) } ?? .null,
                "output_ref": .string("checks/turn-\(n).log"),
            ])
    }

    var state: ThreadState { ThreadState.derive(from: events, id: "t") }
}

@Suite struct ReviewStateTests {
    @Test func emptyLogIsEmpty() {
        #expect(ThreadState.derive(from: [], id: "t").review.status == .empty)
        var story = Story()
        story.add(.threadCreated)
        #expect(story.state.review.status == .empty)
        #expect(story.state.isActive)
    }

    @Test func sameEventsGiveTheSameState() {
        var story = Story()
        story.add(.threadCreated)
        story.turn(1, cost: 0.5)
        story.check(1)
        #expect(story.state == story.state)
    }

    @Test func existingFieldsAreKept() {
        var story = Story()
        story.add(.threadCreated)
        story.turn(1, result: "failed", cost: 0.25)
        story.check(1, result: "failed", exit: 1)
        story.turn(2, cost: 1)
        let state = story.state
        #expect(state.createdAt == "2026-10-13T10:00:00.000Z")
        #expect(state.lastTurn == 2)
        #expect(state.openTurn == nil)
        #expect(state.openCheck == nil)
        #expect(state.lastCheck == "failed")
        #expect(state.lastResult == "succeeded")
        #expect(state.totalCostUSD == 1.25)
        #expect(state.sessionID == "s1")
        #expect(state.decision == nil)
    }

    @Test func reviewHoldsTurnCheckNotesAndDenials() {
        var story = Story()
        story.add(.threadCreated)
        story.turn(1, denied: ["Bash", "Bash"])
        story.check(1, result: "failed", exit: 2)
        story.add(.threadNote, ["text": "fix the failing test"])  // turn 0, as the runner writes it
        story.turn(2, denied: ["Write"])
        let review = story.state.review
        #expect(review.turnResult == "succeeded")
        #expect(review.check == Review.Check(
                turn: 1, result: "failed", exitCode: 2, durationMs: nil, outputRef: "checks/turn-1.log"))
        #expect(review.notes == [Review.Note(turn: 2, seq: 7, text: "fix the failing test")])
        #expect(review.deniedTools.map(\.tool) == ["Bash", "Bash", "Write"])
        #expect(review.deniedTools.map(\.turn) == [1, 1, 2])
        #expect(story.events[review.deniedTools[0].seq - 1].kind == .claude)
    }

    @Test func statusWhatCanBeDecided() {
        var story = Story()
        story.add(.threadCreated)
        story.add(.turnStarted, turn: 1, ["session_id": "s1"])
        #expect(story.state.review.status == .running)

        story.add(.turnEnded, turn: 1, ["result": "succeeded"])
        #expect(story.state.review.status == .awaitingReview)

        story.add(.checkStarted, turn: 1, ["command": "c"])
        #expect(story.state.review.status == .running)
        story.add(.checkRan, turn: 1, ["result": "passed", "exit_code": 0])
        #expect(story.state.review.status == .awaitingReview)

        for decision in ["accepted", "discarded", "abandoned"] {
            var decided = story
            decided.add(.reviewDecision, ["decision": .string(decision), "by": "user"])
            #expect(decided.state.review.status == .decided(decision))
            #expect(decided.state.decision == decision)
            #expect(!decided.state.isActive)
        }
    }

    @Test(arguments: ["stopped", "timed_out", "interrupted", "failed", "budget_exceeded"])
    func anEndedTurnOfAnyResultIsReviewable(result: String) {
        var story = Story()
        story.add(.threadCreated)
        story.turn(1, result: result)
        #expect(story.state.review.status == .awaitingReview)
        #expect(story.state.review.turnResult == result)
    }

    @Test func aNoteAfterTheLastTurnIsSentBackUntilTheNextTurnStarts() {
        var story = Story()
        story.add(.threadCreated)
        story.turn(1)
        story.add(.threadNote, ["text": "again"])
        #expect(story.state.review.status == .sentBack)
        #expect(story.state.review.notes.map(\.turn) == [2])

        story.add(.turnStarted, turn: 2, ["session_id": "s1", "resume": true])
        #expect(story.state.review.status == .running)
        story.add(.turnEnded, turn: 2, ["result": "succeeded"])
        #expect(story.state.review.status == .awaitingReview)
    }

    @Test func abandoningBeforeAnyTurnIsDecided() {
        var story = Story()
        story.add(.threadCreated)
        story.add(.reviewDecision, ["decision": "abandoned", "by": "user"])
        #expect(story.state.review.status == .decided("abandoned"))
    }

    @Test func unknownDecisionsAndKindsAreIgnored() {
        var story = Story()
        story.add(.threadCreated)
        story.turn(1)
        story.add(.reviewDecision, ["decision": "shipped-it", "by": "user"])
        story.add(EventKind(rawValue: "future.kind"), ["anything": 1])
        let state = story.state
        #expect(state.decision == nil)
        #expect(state.review.status == .awaitingReview)
    }
}
