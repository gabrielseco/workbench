import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct RunScreenModelTests {
    private func derive(_ fixture: AppFixture, alive: Bool = true) throws -> RunModel? {
        let project = fixture.project
        let events = try EventLogReader.read(at: project.eventsURL("t1")).events
        let state = ThreadStore(project: project).state(from: events, id: "t1")
        return RunModel.derive(events: events, state: state, runnerAlive: alive, budgetUSD: 5, turnTimeoutMin: 30)
    }

    private func started(_ fixture: AppFixture) async throws {
        try await fixture.addThread("t1", approved: true)
        try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1"], ts: "2026-10-28T11:00:00.000Z")
    }

    private func activity(_ fixture: AppFixture, _ data: [String: JSONValue]) throws {
        var data = data
        data["provider"] = "claude"
        try fixture.append("t1", .agentActivity, turn: 1, data: .object(data), ts: "2026-10-28T11:00:10.000Z")
    }

    @Test func noTurnMeansNoRunScreen() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        #expect(try derive(fixture) == nil)
    }

    @Test func anOpenTurnWithALiveRunnerIsWorkingAndWithoutOneIsOrphaned() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        #expect(try derive(fixture)?.phase == .working)
        #expect(try derive(fixture, alive: false)?.phase == .orphaned)
    }

    @Test func theHeaderSaysHowLongAgoTheTurnStarted() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        let run = try #require(try derive(fixture))
        let now = try #require(RunModel.date("2026-10-28T11:04:00.000Z"))
        #expect(run.header(now: now) == "Turn 1 · started 4m00s ago")
    }

    @Test func activityRowsKeepTheirKindAndEditsCountDistinctFiles() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try activity(fixture, ["type": "text", "text": "Looking at the list"])
        try activity(fixture, ["type": "tool", "name": "Read", "summary": "a.swift"])
        try activity(fixture, ["type": "tool", "name": "Edit", "summary": "a.swift"])
        try activity(fixture, ["type": "tool", "name": "Edit", "summary": "a.swift"])
        try activity(fixture, ["type": "tool", "name": "Write", "summary": "b.swift"])
        try activity(fixture, ["type": "permission_denied", "tool": "Bash"])
        let run = try #require(try derive(fixture))
        #expect(run.rows.map(\.kind) == [.text, .tool, .edit, .edit, .edit, .denied])
        #expect(run.filesChanged == 2 && run.toolCalls == 4 && run.deniedCalls == 1)
        #expect(run.rows.last?.text == "denied Bash")
    }

    @Test func aDroppedRecordIsAVisibleGap() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try activity(fixture, ["type": "dropped", "count": 42, "reason": "cap", "tool_calls": 3, "denied": 0])
        let run = try #require(try derive(fixture))
        #expect(run.rows.first?.kind == .gap && run.rows.first?.text == "42 items not stored")
    }

    @Test func aDeniedRowFillsInFromTheEndOfTheTurn() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try activity(fixture, ["type": "permission_denied", "tool": "Bash"])
        let denials: JSONValue = [["tool": "Bash", "input": "rm -rf build\u{1B}[31m"]]
        try fixture.append(
            "t1", .turnEnded, turn: 1, data: ["result": "succeeded", "permission_denials": 1, "denials": denials])
        let run = try #require(try derive(fixture))
        #expect(run.rows.first?.text == "denied Bash: rm -rf build [31m")
    }

    @Test func textFromTheLogIsOneLineWithNoControlCharacters() {
        #expect(RunModel.clean("a\n\n b\u{7}\tc", limit: 100) == "a b c")
        #expect(RunModel.clean(String(repeating: "x", count: 50), limit: 10) == String(repeating: "x", count: 10) + "…")
    }

    @Test func unreportedNumbersReadUnknownNeverZero() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try fixture.append("t1", .turnEnded, turn: 1, data: ["result": "succeeded"])
        let run = try #require(try derive(fixture))
        #expect(run.spent == "unknown" && run.fraction == nil)
        #expect(run.tests == "not run yet")
    }

    @Test func aGapThatDidNotCountToolCallsLeavesThemUnknown() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try activity(fixture, ["type": "dropped", "count": 5, "reason": "cap"])
        let run = try #require(try derive(fixture))
        #expect(run.toolCalls == nil && run.deniedCalls == nil && run.filesChanged == nil)
    }

    @Test func testsComeFromTheCheckAfterTheTurn() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try fixture.append("t1", .turnEnded, turn: 1, data: ["result": "succeeded", "cost_usd": 1.5])
        try fixture.append(
            "t1", .checkRan, turn: 1,
            data: ["result": "passed", "tests_passed": ["a", "b"], "tests_failed": ["c"]])
        let run = try #require(try derive(fixture))
        #expect(run.tests == "2 passing, 1 failing" && run.spent == "$1.50" && run.fraction == 0.3)
    }

    @Test(arguments: [
        ("stopped", "You stopped this turn."), ("timed_out", "The turn ran past its time limit."),
        ("budget_exceeded", "The turn hit its budget."), ("failed", "The turn failed."),
        ("interrupted", "The runner ended without finishing this turn; the log is intact."),
    ])
    func eachEndedTurnSaysWhy(result: String, reason: String) async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try fixture.append("t1", .turnEnded, turn: 1, data: ["result": .string(result)])
        #expect(try derive(fixture)?.phase == .ended(result: result, reason: reason))
    }

    @Test func aCheckStillRunningAfterTheTurnEndedKeepsTheTurnWorking() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try fixture.append("t1", .turnEnded, turn: 1, data: ["result": "succeeded", "cost_usd": 1.5])
        try fixture.append("t1", .checkStarted, turn: 1)
        #expect(try derive(fixture)?.phase == .checking)
    }

    @Test func theCostOfAFirstOpenTurnIsNotReportedYetNeverZero() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        let run = try #require(try derive(fixture))
        #expect(run.spent == "not reported yet" && run.fraction == nil)
    }

    @Test func anyGapMakesTheFileCountUnknownEvenWhenToolCallsWereCounted() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try activity(fixture, ["type": "tool", "name": "Edit", "summary": "a.swift"])
        try activity(fixture, ["type": "dropped", "count": 5, "reason": "cap", "tool_calls": 3, "denied": 0])
        let run = try #require(try derive(fixture))
        #expect(run.toolCalls == 4 && run.filesChanged == nil)
    }

    @Test func aCheckThatListedNoTestsIsNotSaidToHaveNotRun() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try fixture.append("t1", .turnEnded, turn: 1, data: ["result": "succeeded", "cost_usd": 1.5])
        try fixture.append("t1", .checkRan, turn: 1, data: ["result": "passed"])
        #expect(try derive(fixture)?.tests == "check passed, tests not listed")
    }

    @Test func everyStoredActivityStaysInTheList() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        for index in 0..<650 { try activity(fixture, ["type": "tool", "name": "Edit", "summary": .string("f\(index)")]) }
        let run = try #require(try derive(fixture))
        #expect(run.rows.count == 650 && run.filesChanged == 650)
    }

    @Test func aTurnThatSucceededNeedsNoReason() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        try fixture.append("t1", .turnEnded, turn: 1, data: ["result": "succeeded"])
        #expect(try derive(fixture)?.phase == .ended(result: "succeeded", reason: nil))
    }

    @Test func aQuietTurnSaysForHowLong() async throws {
        let fixture = try await AppFixture()
        try await started(fixture)
        let run = try #require(try derive(fixture))
        let soon = try #require(RunModel.date("2026-10-28T11:00:30.000Z"))
        let later = try #require(RunModel.date("2026-10-28T11:05:00.000Z"))
        #expect(run.quiet(now: soon) == nil)
        #expect(run.quiet(now: later) == 300)
    }

    @Test func aProviderThatReportsNoToolEventsHasUnknownCounts() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1", "provider": "codex"])
        try fixture.append(
            "t1", .agentActivity, turn: 1, data: ["provider": "codex", "type": "text", "text": "hello"])
        let run = try #require(try derive(fixture))
        #expect(run.toolCalls == nil && run.deniedCalls == nil && run.rows.map(\.kind) == [.text])
    }
}
