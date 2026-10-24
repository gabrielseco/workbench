import Foundation
import Testing

@testable import WorkbenchCore

private func tempLog() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("events.jsonl")
}

@Suite struct AgentRecoveryTests {
    private func open() async throws -> (EventLogWriter, URL) {
        let url = try tempLog()
        let log = try EventLogWriter.open(at: url)
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        return (log, url)
    }

    @Test func judgeOrphan() async throws {
        let (log, url) = try await open()
        try await log.append(
            .judgeStarted, turn: 1, data: ["argv": ["claude"], "provider": "claude", "model": "haiku"])
        try await log.startAttempt(role: "judge", turn: 1, provider: .claude, model: nil)
        await log.close()

        let reopened = try EventLogWriter.open(at: url)
        let closed = try await reopened.recoverOrphanedEvaluations()
        #expect(closed.map(\.kind) == [.agentAttemptEnded, .judgeRan], "the attempt ends before the judge")
        #expect(closed[0].data["outcome"] == "interrupted" && closed[0].data["synthetic"] == true)
        let ran = closed[1]
        #expect(ran.data["ok"] == false && ran.data["reason"] == "interrupted" && ran.data["synthetic"] == true)
        #expect(ran.turn == 1 && ran.data["argv"] == ["claude"])
        #expect(ran.data["provider"] == "claude" && ran.data["model"] == "haiku", "the recovered end is attributed too")
        let state = ThreadState.derive(from: try EventLogReader.read(at: url).events, id: "t")
        #expect(state.review.judge?.failure == "interrupted", "no longer 'started and never recorded a result'")
        await reopened.close()
    }

    @Test func reviewOrphan() async throws {
        let (log, url) = try await open()
        try await log.append(
            .prReviewStarted, turn: 1,
            data: ["round": 1, "pr": 7, "head_sha": "abc", "argv": ["codex"], "provider": "codex", "model": .null])
        try await log.startAttempt(role: "review", turn: 1, round: 1, provider: .codex, model: nil)
        await log.close()

        let reopened = try EventLogWriter.open(at: url)
        let closed = try await reopened.recoverOrphanedEvaluations()
        #expect(closed.map(\.kind) == [.agentAttemptEnded, .prReviewFinished])
        let finished = closed[1]
        #expect(finished.data["ok"] == false && finished.data["verdict"] == .null && finished.data["synthetic"] == true)
        #expect(finished.data["round"]?.intValue == 1 && finished.data["pr"]?.intValue == 7)
        #expect(finished.data["head_sha"] == "abc" && finished.data["stage"] == nil)
        #expect(finished.data["provider"] == "codex" && finished.data["model"] == .null)
        await reopened.close()
    }

    @Test func stageOrphan() async throws {
        let (log, url) = try await open()
        try await log.append(
            .reviewStageStarted, turn: 1, data: ["round": 2, "pr": 7, "head_sha": "abc", "stage": "design"])
        await log.close()
        let reopened = try EventLogWriter.open(at: url)
        let closed = try await reopened.recoverOrphanedEvaluations()
        #expect(closed.map(\.kind) == [.reviewStageFinished] && closed[0].data["stage"] == "design")
        await reopened.close()
    }

    @Test func aSkipDoesNotCloseAnotherRound() async throws {
        // A skip writes a finish with no start: it must not close the round that is open.
        let (log, _) = try await open()
        try await log.append(.prReviewStarted, turn: 1, data: ["round": 1, "pr": 7])
        try await log.append(.reviewStageFinished, turn: 1, data: ["stage": "design", "verdict": "skipped", "ok": false])
        let closed = try await log.recoverOrphanedEvaluations()
        #expect(closed.map(\.kind) == [.prReviewFinished], "the pr-review round is still open")
        await log.close()
    }

    @Test func idempotent() async throws {
        let (log, url) = try await open()
        try await log.append(.judgeStarted, turn: 1)
        try await log.append(.prReviewStarted, turn: 1, data: ["round": 1, "pr": 7])
        try await log.startAttempt(role: "review", turn: 1, round: 1, provider: .codex, model: nil)
        #expect(try await log.recoverOrphanedEvaluations().count == 3)
        let size = try EventLogReader.read(at: url).events.count
        #expect(try await log.recoverOrphanedEvaluations().isEmpty)
        #expect(try await log.recoverOrphanedAttempts().isEmpty)
        #expect(try EventLogReader.read(at: url).events.count == size, "a second recovery writes nothing")
        await log.close()
    }

    @Test func capsAreNotReset() async throws {
        let (log, url) = try await open()
        for round in 1...3 {
            try await log.append(.prReviewStarted, turn: 1, data: ["round": .int(round), "pr": 7])
            if round < 3 { try await log.append(.prReviewFinished, turn: 1, data: ["round": .int(round), "pr": 7, "ok": true]) }
        }
        try await log.recoverOrphanedEvaluations()
        let events = try EventLogReader.read(at: url).events
        #expect(events.filter { $0.kind == .prReviewStarted }.count == 3, "the interrupted round still counts")
        let last = try #require(events.last)
        #expect(last.kind == .prReviewFinished && last.data["ok"] == false && last.data["verdict"] == .null, "not a pass")
        await log.close()
    }

    @Test func aKilledTurnClosesItsRunAttempt() async throws {
        let url = try tempLog()
        let log = try EventLogWriter.open(at: url)
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        try await log.startAttempt(role: "run", turn: 1, provider: .claude, model: nil)
        try await log.recoverOrphanedTurn()
        let kinds = try EventLogReader.read(at: url).events.map(\.kind)
        #expect(kinds.suffix(2) == [.agentAttemptEnded, .turnEnded])
        #expect(!(await log.hasOpenAttempt))
        await log.close()
    }
}
