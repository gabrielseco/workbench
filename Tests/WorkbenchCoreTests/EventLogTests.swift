import Foundation
import Testing

@testable import WorkbenchCore

private func tempLog() throws -> URL {
    let dir = Scratch.url("wb")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("events.jsonl")
}

private func lines(of url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

@Suite struct EventLogTests {
    // MARK: envelope, seq, replay

    @Test func appendAssignsSequentialSeqAndReplays() async throws {
        let url = try tempLog()
        let log = try EventLogWriter.open(at: url)
        try await log.append(.threadCreated, data: ["repo": "/r", "branch": "workbench/t1"])
        try await log.append(.turnStarted, turn: 1, data: ["session_id": "abc", "resume": false])
        try await log.append(.agentActivity, turn: 1, data: ["provider": "claude", "type": "text", "text": "hi"])
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded", "exit_code": 0])

        let contents = try EventLogReader.read(at: url)
        #expect(contents.isHealthy)
        #expect(contents.events.map(\.seq) == [1, 2, 3, 4])
        #expect(contents.events.map(\.kind) == [.threadCreated, .turnStarted, .agentActivity, .turnEnded])
        #expect(contents.events[0].v == 1)
        #expect(contents.events[0].data["branch"] == "workbench/t1")
        #expect(contents.events[3].data["exit_code"]?.intValue == 0)
        #expect(contents.openTurn == nil)
    }

    @Test func timestampIsIso8601WithMilliseconds() async throws {
        let url = try tempLog()
        let log = try EventLogWriter.open(at: url, now: { Date(timeIntervalSince1970: 1_700_000_000.125) })
        let event = try await log.append(.threadCreated)
        #expect(event.ts == "2023-11-14T22:13:20.125Z")
    }

    // MARK: invariant 1, turns

    @Test func activityOutsideTurnIsRejected() async throws {
        let log = try EventLogWriter.open(at: try tempLog())
        await #expect(throws: EventLogError.invalid(.activityOutsideTurn(turn: 1, line: 0))) {
            try await log.append(.agentActivity, turn: 1, data: ["type": "text"])
        }
        try await log.append(.turnStarted, turn: 1)
        try await log.append(.agentActivity, turn: 1, data: ["type": "text"])
        try await log.append(.turnEnded, turn: 1)
        await #expect(throws: EventLogError.invalid(.activityOutsideTurn(turn: 1, line: 0))) {
            try await log.append(.agentActivity, turn: 1, data: ["type": "text"])
        }
        #expect(await log.nextSeq == 4, "a rejected append consumes no seq, and the accepted one left no gap")
    }

    @Test func writerRejectsTurnRuleViolations() async throws {
        let log = try EventLogWriter.open(at: try tempLog())

        await #expect(throws: EventLogError.invalid(.turnEndedWithoutStart(turn: 1, line: 0))) {
            try await log.append(.turnEnded, turn: 1)
        }
        await #expect(throws: EventLogError.invalid(.turnNotConsecutive(expected: 1, found: 2, line: 0))) {
            try await log.append(.turnStarted, turn: 2)
        }

        try await log.append(.turnStarted, turn: 1)
        await #expect(throws: EventLogError.invalid(.turnStartedWhileOpen(turn: 2, open: 1, line: 0))) {
            try await log.append(.turnStarted, turn: 2)
        }
        try await log.append(.turnEnded, turn: 1)
        // Rejected appends must not have consumed a seq.
        #expect(await log.nextSeq == 3)
    }

    @Test func orphanedTurnIsRecoveredAsInterruptedOnReopen() async throws {
        let url = try tempLog()
        do {
            let log = try EventLogWriter.open(at: url)
            try await log.append(.turnStarted, turn: 1)
            try await log.append(.agentActivity, turn: 1, data: ["provider": "claude", "type": "text", "text": "hi"])
            // runner "dies" here: no turn.ended
            await log.close()
        }

        #expect(try EventLogReader.read(at: url).openTurn == 1)

        let log = try EventLogWriter.open(at: url)
        #expect(await log.openTurn == 1)
        let recovered = try #require(try await log.recoverOrphanedTurn())
        #expect(recovered.kind == .turnEnded)
        #expect(recovered.turn == 1)
        #expect(recovered.data["result"] == "interrupted")
        #expect(recovered.data["synthetic"] == true)
        #expect(try await log.recoverOrphanedTurn() == nil)

        try await log.append(.turnStarted, turn: 2)
        let contents = try EventLogReader.read(at: url)
        #expect(contents.isHealthy)
        #expect(contents.events.map(\.seq) == [1, 2, 3, 4])
    }

    // MARK: invariant 2, seq

    @Test func reopenContinuesSeq() async throws {
        let url = try tempLog()
        do {
            let log = try EventLogWriter.open(at: url)
            try await log.append(.threadCreated)
            try await log.append(.goalSaved)
            await log.close()
        }
        let log = try EventLogWriter.open(at: url)
        let event = try await log.append(.goalApproved)
        #expect(event.seq == 3)
    }

    @Test func readerReportsSeqGapAndWriterRefusesDamagedLog() async throws {
        let url = try tempLog()
        let content = """
            {"v":1,"seq":1,"ts":"t","turn":0,"kind":"thread.created","data":{}}
            {"v":1,"seq":3,"ts":"t","turn":0,"kind":"goal.saved","data":{}}

            """
        try content.write(to: url, atomically: true, encoding: .utf8)

        let contents = try EventLogReader.read(at: url)
        #expect(contents.problems == [.seqMismatch(expected: 2, found: 3, line: 2)])
        #expect(throws: EventLogError.corrupt([.seqMismatch(expected: 2, found: 3, line: 2)])) {
            _ = try EventLogWriter.open(at: url)
        }
        // The damaged file is left alone.
        #expect(try String(contentsOf: url, encoding: .utf8) == content)
    }

    @Test func invalidLineInTheMiddleIsAProblem() throws {
        let url = try tempLog()
        let content = """
            {"v":1,"seq":1,"ts":"t","turn":0,"kind":"thread.created","data":{}}
            garbage
            {"v":1,"seq":2,"ts":"t","turn":0,"kind":"goal.saved","data":{}}

            """
        try content.write(to: url, atomically: true, encoding: .utf8)
        #expect(try EventLogReader.read(at: url).problems == [.invalidLine(line: 2)])
    }

    // MARK: crash artifacts

    @Test func halfWrittenFinalLineIsRemovedAndKeptAside() async throws {
        let url = try tempLog()
        let complete = #"{"v":1,"seq":1,"ts":"t","turn":0,"kind":"thread.created","data":{}}"# + "\n"
        let partial = #"{"v":1,"seq":2,"ts":"t","turn":0,"ki"#
        try (complete + partial).write(to: url, atomically: true, encoding: .utf8)

        let read = try EventLogReader.read(at: url)
        #expect(read.problems.isEmpty)
        #expect(read.truncatedTail == Data(partial.utf8))

        let log = try EventLogWriter.open(at: url)
        #expect(log.repairedTailBytes == partial.utf8.count)
        let event = try await log.append(.goalSaved)
        #expect(event.seq == 2)

        #expect(try EventLogReader.read(at: url).isHealthy)
        let sidecar = try String(contentsOf: url.appendingPathExtension("truncated"), encoding: .utf8)
        #expect(sidecar.hasPrefix(partial))
    }

    // MARK: single writer

    @Test func secondWriterIsRefused() async throws {
        let url = try tempLog()
        let first = try EventLogWriter.open(at: url)
        #expect(throws: EventLogError.alreadyOpen(path: url.path)) {
            _ = try EventLogWriter.open(at: url, lockTimeout: 0)
        }
        try await first.append(.threadCreated)
    }

    // MARK: forward compatibility

    @Test func readerIgnoresUnknownKindsAndFields() throws {
        let url = try tempLog()
        let content = """
            {"v":2,"seq":1,"ts":"t","turn":0,"kind":"future.thing","extra":[1,2],"data":{"x":{"y":null}}}
            {"v":1,"seq":2,"ts":"t","turn":0,"kind":"thread.created","data":{},"note":"hi"}

            """
        try content.write(to: url, atomically: true, encoding: .utf8)
        let contents = try EventLogReader.read(at: url)
        #expect(contents.isHealthy)
        #expect(contents.events.map(\.kind.rawValue) == ["future.thing", "thread.created"])
    }

    @Test func realClaudeOutputRoundTripsVerbatim() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plan/P1-spikes/fixtures/s1-read-2.jsonl")
        let raw = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map(String.init)
        try #require(!raw.isEmpty)

        // Real stream lines go through the transcript writer exactly as they came.
        let url = TranscriptFile.url(in: try tempLog().deletingLastPathComponent(), turn: 1)
        let writer = TranscriptWriter(url: url)
        for line in raw { try writer.append(line) }
        writer.close()

        let stored = TranscriptFile.read(at: url).lines
        #expect(stored.map(\.rawData) == raw)
    }

    @Test func closeReleasesTheLockAndStopsAppends() async throws {
        let url = try tempLog()
        let first = try EventLogWriter.open(at: url)
        try await first.append(.threadCreated)
        await first.close()
        await first.close()  // idempotent

        await #expect(throws: EventLogError.io("event log is closed")) {
            try await first.append(.goalSaved)
        }
        let second = try EventLogWriter.open(at: url)
        #expect(try await second.append(.goalSaved).seq == 2)
    }

    @Test func missingFileIsAnError() {
        let url = Scratch.url("nope", ext: "jsonl")
        #expect(throws: EventLogError.self) { _ = try EventLogReader.read(at: url) }
    }
}
