import Foundation
import Testing

@testable import WorkbenchCore

private func tempLog() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("events.jsonl")
}

@Suite struct AgentEventsTests {
    @Test func attemptsPairUp() async throws {
        let url = try tempLog()
        let log = try EventLogWriter.open(at: url)
        try await log.append(.threadCreated)
        let first = try await log.startAttempt(role: "judge", turn: 1, provider: .claude, model: "haiku")
        let second = try await log.startAttempt(role: "review", stage: "design", round: 2, provider: .codex, model: nil)
        #expect(first != second && first == "a2")
        #expect(await log.hasOpenAttempt)
        #expect(try await log.endAttempt(first, outcome: "succeeded") != nil)
        #expect(try await log.endAttempt(first, outcome: "failed") == nil, "an attempt closes once")
        #expect(try await log.endAttempt("a99", outcome: "failed") == nil)
        try await log.endAttempt(second, outcome: "timed_out", reason: "too slow")

        let events = try EventLogReader.read(at: url).events
        let started = events.filter { $0.kind == .agentAttemptStarted }
        #expect(started[0].data["role"] == "judge" && started[0].data["provider"] == "claude")
        #expect(started[0].data["model"] == "haiku" && started[0].turn == 1)
        #expect(started[1].data["stage"] == "design" && started[1].data["round"]?.intValue == 2)
        #expect(started[1].data["model"] == .null, "no model means the provider's own default")
        let ends = events.filter { $0.kind == .agentAttemptEnded }
        #expect(ends.map { $0.data["attempt"]?.stringValue } == [first, second])
        #expect(ends[0].turn == 1, "an end belongs to the turn its start did")
        #expect(ends[1].data["outcome"] == "timed_out" && ends[1].data["reason"] == "too slow")
        #expect(!(await log.hasOpenAttempt))
    }

    @Test func refusedAttempt() async throws {
        let url = try tempLog()
        let log = try EventLogWriter.open(at: url)
        let agent = ResolvedAgent(provider: .codex, model: nil, allowUnpriced: false)
        try await AttemptLog(log: log, role: "review", round: 1, agent: agent).refused("`codex` was not found")
        let events = try EventLogReader.read(at: url).events
        #expect(events.map(\.kind) == [.agentAttemptStarted, .agentAttemptEnded])
        #expect(events[0].data["spawned"] == false, "nothing was started")
        #expect(events[1].data["outcome"] == "refused" && events[1].data["reason"] == "`codex` was not found")
        #expect(!(await log.hasOpenAttempt))
    }

    @Test func draftKindsAreInert() async throws {
        let url = try tempLog()
        let log = try EventLogWriter.open(at: url)
        try await log.append(.threadCreated)
        try await log.append(.goalDraftStarted, data: ["provider": "codex", "model": .null, "attempt": "a2"])
        try await log.append(.goalDraftFinished, data: ["ok": true, "proposal_ref": "goal-draft.md", "provider": "codex"])
        let events = try EventLogReader.read(at: url).events
        #expect(try EventLogReader.read(at: url).isHealthy)
        let state = ThreadState.derive(from: events, id: "t")
        #expect(state.lastTurn == 0 && state.decision == nil, "no turn, no approval")
        var logState = LogState()
        for event in events { logState.apply(event) }
        #expect(logState.openTurn == nil && logState.judgeStart == nil && logState.reviewStart == nil)
    }

    @Test func oldLogsReplay() throws {
        // A log from before provider and model existed: the judge, the round and their ends carry neither.
        func event(_ seq: Int, _ kind: EventKind, turn: Int = 1, _ data: JSONValue) -> Event {
            Event(seq: seq, ts: "2026-10-01T10:00:0\(seq % 10).000Z", turn: turn, kind: kind, data: data)
        }
        let events = [
            event(1, .threadCreated, turn: 0, ["repo": "/r", "base": "main", "worktree": "/w", "branch": "workbench/t"]),
            event(2, .turnStarted, ["session_id": "s", "resume": false]),
            event(3, .turnEnded, ["result": "succeeded", "exit_code": 0]),
            event(4, .judgeStarted, ["argv": ["claude"]]),
            event(5, .judgeRan, ["ok": false, "reason": "the judge was stopped", "argv": ["claude"]]),
            event(6, .prReviewStarted, ["round": 1, "pr": 3, "head_sha": "abc", "argv": ["codex"]]),
            event(7, .prReviewFinished, ["round": 1, "pr": 3, "head_sha": "abc", "ok": true, "verdict": "clean"]),
        ]
        let state = ThreadState.derive(from: events, id: "t")
        #expect(state.review.judge?.failure?.contains("stopped") == true)
        #expect(state.review.prReview?.round == 1 && state.review.prReview?.verdict == "clean")
        var logState = LogState()
        for event in events {
            #expect(logState.check(event) == nil)
            logState.apply(event)
        }
        #expect(logState.judgeStart == nil && logState.reviewStart == nil && logState.openAttempts.isEmpty)
    }

    @Test func newKindsReplay() async throws {
        let url = try tempLog()
        let log = try EventLogWriter.open(at: url)
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1, data: ["provider": "claude", "model": "opus"])
        let run = try await log.startAttempt(role: "run", turn: 1, provider: .claude, model: "opus")
        try await log.endAttempt(run, outcome: "succeeded")
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        try await log.append(.goalDraftStarted, data: ["provider": "codex"])
        try await log.append(.goalDraftFinished, data: ["ok": false, "reason": "interrupted", "synthetic": true])
        try await log.append(.judgeStarted, turn: 1, data: ["provider": "claude", "model": .null])
        try await log.recoverOrphanedEvaluations()
        await log.close()

        let contents = try EventLogReader.read(at: url)
        #expect(contents.isHealthy && contents.events.allSatisfy { $0.v == 1 }, "version 1 is kept: every change is additive")
        let reopened = try EventLogWriter.open(at: url)
        #expect(await reopened.nextSeq == contents.events.count + 1)
        #expect(!(await reopened.hasOpenAttempt))
        await reopened.close()
    }

    @Test func writeFailureStopsTheChild() async throws {
        // The attempt is on record before the process exists, so a log that cannot take it means nothing is started.
        let url = try tempLog()
        let log = try EventLogWriter.open(at: url)
        try await log.append(.threadCreated)
        await log.close()
        let agent = ResolvedAgent(provider: .claude, model: nil, allowUnpriced: false)
        await #expect(throws: (any Error).self) { try await AttemptLog(log: log, role: "judge", agent: agent).start() }
        #expect(try EventLogReader.read(at: url).events.count == 1, "nothing was half-written")
        let reopened = try EventLogWriter.open(at: url)
        #expect(!(await reopened.hasOpenAttempt))
        await reopened.close()
    }
}

@Suite(.processGate) struct TurnAttemptTests {
    @Test func metadataOnStartsAndEnds() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let events = try fx.events(id)
        let turn = events.firstIndex { $0.kind == .turnStarted } ?? 0
        #expect(
            events[turn...].prefix(2).map(\.kind) == [.turnStarted, .agentAttemptStarted],
            "the attempt follows the turn start")
        #expect(events[turn].data["provider"] == "claude" && events[turn].data["model"] == .null)
        let attempt = events[turn + 1]
        #expect(attempt.data["role"] == "run" && attempt.turn == 1 && attempt.data["provider"] == "claude")
        let ends = events.suffix(2)
        #expect(ends.map(\.kind) == [.agentAttemptEnded, .turnEnded], "the attempt ends before the turn")
        #expect(ends.first?.data["outcome"] == "succeeded" && ends.first?.data["attempt"] == attempt.data["attempt"])
        #expect(try fx.contents(id).isHealthy)
    }
}
