import Foundation
import Testing

@testable import WorkbenchCore

/// A log built by hand: `NextSteps` is a pure function of the events, the changed files and the config.
private struct Entry {
    var kind: EventKind
    var turn: Int
    var data: JSONValue = [:]
}

private func log(_ entries: [Entry]) -> [Event] {
    entries.enumerated().map { index, entry in
        Event(seq: index + 1, ts: "2026-10-29T10:00:00.000Z", turn: entry.turn, kind: entry.kind, data: entry.data)
    }
}

private func config(appliesTo: String? = nil) throws -> Config {
    let applies = appliesTo.map { "applies_to = [\"\($0)\"]\n" } ?? ""
    let text = """
        check_command = "make test"
        [tools]
        available = ["Read"]
        allowed = ["Read"]
        [review]
        stages = ["pr-review", "design"]
        [review.stage.design]
        skill = "d.md"
        \(applies)
        """
    return try Config.parse(text)
}

private let turn1 = [Entry(kind: .turnStarted, turn: 1), Entry(kind: .turnEnded, turn: 1, data: ["result": "succeeded"])]

@Suite struct NextStepsTests {
    @Test func aFinishedTurnWithNoJudgeAndAMatchingStageListsBothThenTheDecision() throws {
        let steps = NextSteps.derive(events: log(turn1), files: ["Sources/A.swift"], config: try config(appliesTo: "Sources/**"))
        #expect(steps.map(\.name) == ["judge", "design", "accept"])
        #expect(steps[1].command == "workbench review-stage design")
    }

    @Test func aStageThatAppliesToNothingTheChangeTouchesIsLeftOut() throws {
        let steps = NextSteps.derive(events: log(turn1), files: ["docs/x.md"], config: try config(appliesTo: "Sources/**"))
        #expect(steps.map(\.name) == ["judge", "accept"])
    }

    @Test func aJudgeForThisTurnAndAStageRunAfterItAreDone() throws {
        let events = log(
            turn1 + [
                Entry(kind: .judgeRan, turn: 1, data: ["ok": true]),
                Entry(kind: .reviewStageFinished, turn: 0, data: ["stage": "design", "verdict": "clean"]),
            ])
        #expect(NextSteps.derive(events: events, files: ["a"], config: try config()).map(\.name) == ["accept"])
    }

    @Test func aJudgeOfAnEarlierTurnAndAStageRunBeforeTheLatestTurnAreDueAgain() throws {
        let events = log([
            Entry(kind: .turnStarted, turn: 1), Entry(kind: .turnEnded, turn: 1, data: ["result": "succeeded"]),
            Entry(kind: .judgeRan, turn: 1, data: ["ok": true]),
            Entry(kind: .reviewStageFinished, turn: 0, data: ["stage": "design", "verdict": "clean"]),
            Entry(kind: .turnStarted, turn: 2), Entry(kind: .turnEnded, turn: 2, data: ["result": "succeeded"]),
        ])
        #expect(NextSteps.derive(events: events, files: ["a"], config: try config()).map(\.name) == ["judge", "design", "accept"])
    }

    @Test func aSkippedStageRoundIsNotARun() throws {
        let events = log(turn1 + [Entry(kind: .reviewStageFinished, turn: 0, data: ["stage": "design", "verdict": "skipped"])])
        #expect(NextSteps.derive(events: events, files: ["a"], config: try config()).map(\.name).contains("design"))
    }

    @Test func afterAcceptTheStepsAreTheStagesAndShipAndAfterThePullRequestNothing() throws {
        let accept = Entry(kind: .reviewDecision, turn: 1, data: ["decision": "accepted"])
        let accepted = log(turn1 + [accept])
        #expect(NextSteps.derive(events: accepted, files: ["a"], config: try config()).map(\.name) == ["judge", "design", "ship"])
        let shipped = log(turn1 + [accept, Entry(kind: .prOpened, turn: 0)])
        #expect(NextSteps.derive(events: shipped, files: ["a"], config: try config()).isEmpty)
    }

    @Test func nothingIsDueBeforeATurnEndedOrAfterItFailedOrTheThreadWasDiscarded() throws {
        let cfg = try config()
        #expect(NextSteps.derive(events: log([Entry(kind: .turnStarted, turn: 1)]), files: [], config: cfg).isEmpty)
        let failed = log([Entry(kind: .turnStarted, turn: 1), Entry(kind: .turnEnded, turn: 1, data: ["result": "failed"])])
        #expect(NextSteps.derive(events: failed, files: [], config: cfg).isEmpty)
        let discarded = log(turn1 + [Entry(kind: .reviewDecision, turn: 1, data: ["decision": "discarded"])])
        #expect(NextSteps.derive(events: discarded, files: [], config: cfg).isEmpty)
    }

    @Test func aSendBackAndANewTurnReopenTheListForTheNewTurn() throws {
        let events = log(
            turn1 + [
                Entry(kind: .threadNote, turn: 1, data: ["text": "fix it"]),
                Entry(kind: .turnStarted, turn: 2), Entry(kind: .turnEnded, turn: 2, data: ["result": "succeeded"]),
            ])
        #expect(NextSteps.derive(events: events, files: ["a"], config: try config()).map(\.name) == ["judge", "design", "accept"])
    }

    @Test func unreadableChangedFilesStillListTheStageAndSaySo() throws {
        let steps = NextSteps.derive(events: log(turn1), files: nil, config: try config(appliesTo: "Sources/**"))
        #expect(steps.first { $0.name == "design" }?.why.contains("could not be read") == true)
    }

    @Test func withNoConfigOnlyTheJudgeAndTheDecisionAreListed() {
        #expect(NextSteps.derive(events: log(turn1), files: nil, config: nil).map(\.name) == ["judge", "accept"])
    }

    @Test func renderingMarksTheFirstStepAsNextAndAlignsTheRest() {
        let lines = NextSteps.render([
            NextStep(name: "judge", command: "workbench judge", why: "w1"),
            NextStep(name: "accept", command: "workbench accept", why: "w2"),
        ])
        #expect(lines.count == 2 && lines[0].hasPrefix("next  workbench judge") && lines[1].hasPrefix("then  workbench accept"))
        #expect(NextSteps.render([]).isEmpty)
    }
}
