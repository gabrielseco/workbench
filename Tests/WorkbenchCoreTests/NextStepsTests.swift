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
        let steps = NextSteps.derive(events: log(turn1), files: ["Sources/A.swift"],
            config: try config(appliesTo: "Sources/**"), id: "t1")
        #expect(steps.map(\.name) == ["judge", "design", "accept"])
        #expect(steps[1].command == "workbench review-stage design t1")
    }

    @Test func aStageThatAppliesToNothingTheChangeTouchesIsLeftOut() throws {
        let steps = NextSteps.derive(events: log(turn1), files: ["docs/x.md"],
            config: try config(appliesTo: "Sources/**"), id: "t1")
        #expect(steps.map(\.name) == ["judge", "accept"])
    }

    @Test func aJudgeForThisTurnAndAStageRunAfterItAreDone() throws {
        let events = log(
            turn1 + [
                Entry(kind: .judgeRan, turn: 1, data: ["ok": true]),
                Entry(kind: .reviewStageFinished, turn: 0, data: ["stage": "design", "verdict": "clean"]),
            ])
        #expect(NextSteps.derive(events: events, files: ["a"], config: try config(), id: "t1").map(\.name) == ["accept"])
    }

    @Test func aJudgeOfAnEarlierTurnAndAStageRunBeforeTheLatestTurnAreDueAgain() throws {
        let events = log([
            Entry(kind: .turnStarted, turn: 1), Entry(kind: .turnEnded, turn: 1, data: ["result": "succeeded"]),
            Entry(kind: .judgeRan, turn: 1, data: ["ok": true]),
            Entry(kind: .reviewStageFinished, turn: 0, data: ["stage": "design", "verdict": "clean"]),
            Entry(kind: .turnStarted, turn: 2), Entry(kind: .turnEnded, turn: 2, data: ["result": "succeeded"]),
        ])
        #expect(NextSteps.derive(events: events, files: ["a"],
            config: try config(), id: "t1").map(\.name) == ["judge", "design", "accept"])
    }

    @Test func aSkippedStageRoundIsNotARun() throws {
        let events = log(turn1 + [Entry(kind: .reviewStageFinished, turn: 0, data: ["stage": "design", "verdict": "skipped"])])
        #expect(NextSteps.derive(events: events, files: ["a"], config: try config(), id: "t1").map(\.name).contains("design"))
    }

    @Test func afterAcceptTheStepsAreTheStagesAndShipAndAfterThePullRequestNothing() throws {
        let accept = Entry(kind: .reviewDecision, turn: 1, data: ["decision": "accepted"])
        let accepted = log(turn1 + [accept])
        #expect(NextSteps.derive(events: accepted, files: ["a"],
            config: try config(), id: "t1").map(\.name) == ["judge", "design", "ship"])
        let shipped = log(turn1 + [accept, Entry(kind: .prOpened, turn: 0)])
        #expect(NextSteps.derive(events: shipped, files: ["a"], config: try config(), id: "t1").isEmpty)
    }

    @Test func nothingIsDueBeforeATurnEndedOrAfterItFailedOrTheThreadWasDiscarded() throws {
        let cfg = try config()
        #expect(NextSteps.derive(events: log([Entry(kind: .turnStarted, turn: 1)]), files: [], config: cfg, id: "t1").isEmpty)
        let failed = log([Entry(kind: .turnStarted, turn: 1), Entry(kind: .turnEnded, turn: 1, data: ["result": "failed"])])
        #expect(NextSteps.derive(events: failed, files: [], config: cfg, id: "t1").isEmpty)
        let discarded = log(turn1 + [Entry(kind: .reviewDecision, turn: 1, data: ["decision": "discarded"])])
        #expect(NextSteps.derive(events: discarded, files: [], config: cfg, id: "t1").isEmpty)
    }

    @Test func aSendBackAndANewTurnReopenTheListForTheNewTurn() throws {
        let events = log(
            turn1 + [
                Entry(kind: .threadNote, turn: 1, data: ["text": "fix it"]),
                Entry(kind: .turnStarted, turn: 2), Entry(kind: .turnEnded, turn: 2, data: ["result": "succeeded"]),
            ])
        #expect(NextSteps.derive(events: events, files: ["a"],
            config: try config(), id: "t1").map(\.name) == ["judge", "design", "accept"])
    }

    @Test func unreadableChangedFilesStillListTheStageAndSaySo() throws {
        let steps = NextSteps.derive(events: log(turn1), files: nil, config: try config(appliesTo: "Sources/**"), id: "t1")
        #expect(steps.first { $0.name == "design" }?.why.contains("could not be read") == true)
    }

    @Test func withNoConfigOnlyTheJudgeAndTheDecisionAreListed() {
        #expect(NextSteps.derive(events: log(turn1), files: nil, config: nil, id: "t1").map(\.name) == ["judge", "accept"])
    }

    @Test func everyCommandNamesTheThreadSoANamedThreadNeverActsOnTheActiveOne() throws {
        let accepted = log(turn1 + [Entry(kind: .reviewDecision, turn: 1, data: ["decision": "accepted"])])
        let steps = NextSteps.derive(events: accepted, files: ["a"], config: try config(), id: "g-2026-t1")
        #expect(steps.count == 3 && steps.allSatisfy { $0.command.contains("g-2026-t1") })
        let open = NextSteps.derive(events: log(turn1), files: ["a"], config: try config(), id: "g-2026-t1")
        #expect(open.last?.command == "workbench accept g-2026-t1 -m \"<message>\"")
    }

    @Test func aStageReviewedAtAnOlderHeadIsDueAgain() throws {
        let events = log(
            turn1 + [
                Entry(kind: .judgeRan, turn: 1, data: ["ok": true]),
                Entry(kind: .reviewStageFinished, turn: 0, data: ["stage": "design", "verdict": "clean", "head_sha": "h1"]),
            ])
        let same = NextSteps.derive(events: events, files: ["a"], config: try config(), head: "h1", id: "t1")
        #expect(same.map(\.name) == ["accept"])
        let moved = NextSteps.derive(events: events, files: ["a"], config: try config(), head: "h2", id: "t1")
        #expect(moved.map(\.name) == ["design", "accept"])
        let unknown = NextSteps.derive(events: events, files: ["a"], config: try config(), head: nil, id: "t1")
        #expect(unknown.map(\.name) == ["accept"], "no head to compare: the round counts")
    }

    @Test func aNewerTurnThatHasNotEndedReplacesTheListWithAWait() throws {
        let events = log(turn1 + [Entry(kind: .judgeRan, turn: 1, data: ["ok": true]), Entry(kind: .turnStarted, turn: 2)])
        let steps = NextSteps.derive(events: events, files: ["a"], config: try config(), id: "t1")
        #expect(steps.map(\.name) == ["wait"] && steps[0].why.contains("turn 2"))
    }

    @Test func aRenameOutOfTheStagesPathsStillMakesTheStageApply() throws {
        let moved = FileChange(
            path: "Archive/A.swift", oldPath: "Sources/A.swift", status: .renamed, isBinary: false, isUntracked: false)
        let paths = NextSteps.paths(of: [moved])
        #expect(paths == ["Archive/A.swift", "Sources/A.swift"])
        let steps = NextSteps.derive(events: log(turn1), files: paths, config: try config(appliesTo: "Sources/**"), id: "t1")
        #expect(steps.map(\.name) == ["judge", "design", "accept"])
    }

    @Test func aStoppedTurnHasNothingDue() throws {
        let stopped = log([Entry(kind: .turnStarted, turn: 1), Entry(kind: .turnEnded, turn: 1, data: ["result": "stopped"])])
        #expect(NextSteps.derive(events: stopped, files: ["a"], config: try config(), id: "t1").isEmpty)
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
