import Foundation
import Testing

@testable import WorkbenchCore

private func thread() throws -> URL {
    let directory = Scratch.url("transcript")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func raw(_ n: Int) -> String { #"{"type":"assistant","n":\#(n)}"# }

@Suite struct TranscriptFileTests {
    @Test func linesAreStoredVerbatimInOrderAndCounted() throws {
        let url = TranscriptFile.url(in: try thread(), turn: 1)
        let writer = TranscriptWriter(url: url, now: { Date(timeIntervalSince1970: 0) })
        try writer.append(raw(1))
        try writer.append("not json {")
        try writer.append(String(repeating: "x", count: 50), )
        try writer.appendOversized(preview: "abc", totalBytes: 9_000_000)
        writer.close()

        let stored = TranscriptFile.read(at: url).lines
        #expect(stored.map(\.rawData) == [
            raw(1), #"{"invalid_json":"not json {"}"#, #"{"invalid_json":"\#(String(repeating: "x", count: 50))"}"#,
            #"{"original_bytes":9000000,"prefix":"abc","truncated":true}"#,
        ])
        #expect(stored.allSatisfy { $0.ts == "1970-01-01T00:00:00.000Z" })
        let summary = try #require(TranscriptFile.summary(at: url))
        #expect(summary.lines == 4)
        #expect(summary.bytes == (try Data(contentsOf: url)).count)
        #expect(writer.summary == summary)
    }

    @Test func aLineOverTheLimitIsAMarkerNotTheLine() throws {
        let url = TranscriptFile.url(in: try thread(), turn: 1)
        let writer = TranscriptWriter(url: url, maxLineBytes: 100)
        try writer.append(#"{"pad":"\#(String(repeating: "y", count: 500))"}"#)
        writer.close()
        let line = try #require(TranscriptFile.lines(at: url, turn: 1).first)
        #expect(line.data["truncated"] == true && (line.data["original_bytes"]?.intValue ?? 0) > 500)
        #expect((try Data(contentsOf: url)).count < 5000)
    }

    @Test func aTornLastLineIsNotALineAndRepairCutsIt() throws {
        let url = TranscriptFile.url(in: try thread(), turn: 1)
        let writer = TranscriptWriter(url: url)
        try writer.append(raw(1))
        try writer.append(raw(2))
        writer.close()
        let whole = try Data(contentsOf: url).count
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"ts":"2026-10-24T00:00:00.000Z","data":{"type":"ass"#.utf8))
        try handle.close()

        #expect(TranscriptFile.lines(at: url, turn: 1).count == 2)
        #expect(TranscriptFile.summary(at: url) == TranscriptSummary(lines: 2, bytes: whole))
        #expect(TranscriptFile.repair(at: url) == TranscriptSummary(lines: 2, bytes: whole))
        #expect(try Data(contentsOf: url).count == whole, "the torn line is gone")
        #expect(TranscriptFile.repair(at: url.appendingPathExtension("missing")) == nil)
    }

    @Test func readingFromAnOffsetGivesOnlyWhatIsNew() throws {
        let url = TranscriptFile.url(in: try thread(), turn: 1)
        let writer = TranscriptWriter(url: url)
        try writer.append(raw(1))
        let first = TranscriptFile.read(at: url)
        #expect(first.lines.count == 1)
        try writer.append(raw(2))
        try writer.append(raw(3))
        let next = TranscriptFile.read(at: url, from: first.offset)
        #expect(next.lines.map(\.rawData) == [raw(2), raw(3)])
        #expect(TranscriptFile.read(at: url, from: next.offset).lines.isEmpty)
    }

    @Test func recoveringATurnCountsWhatTheDeadRunnerWrote() async throws {
        let directory = try thread()
        let log = try EventLogWriter.open(at: directory.appendingPathComponent("events.jsonl"))
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        let url = TranscriptFile.url(in: directory, turn: 1)
        let writer = TranscriptWriter(url: url)
        try writer.append(raw(1))
        try writer.append(raw(2))
        writer.close()
        let whole = try Data(contentsOf: url).count
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"ts":"x","data":{"#.utf8))
        try handle.close()

        let ended = try #require(try await log.recoverOrphanedTurn())
        #expect(ended.data["result"] == "interrupted" && ended.data["synthetic"] == true)
        #expect(ended.data["transcript"] == ["lines": 2, "bytes": .int(whole)])
        // Recovery cut the torn line, then gzipped the file: the same lines and bytes read back from the .gz.
        #expect(TranscriptFile.summary(at: url) == TranscriptSummary(lines: 2, bytes: whole))
        await log.close()
    }

    @Test func aTurnThatWroteNoTranscriptRecoversWithoutTheField() async throws {
        let directory = try thread()
        let log = try EventLogWriter.open(at: directory.appendingPathComponent("events.jsonl"))
        try await log.append(.turnStarted, turn: 1)
        let ended = try #require(try await log.recoverOrphanedTurn())
        #expect(ended.data["transcript"] == nil)
        await log.close()
    }

    @Test func aResultLineReachesTheLogEvenIfTheTranscriptCannotBeWritten() async throws {
        let directory = try thread()
        let log = try EventLogWriter.open(at: directory.appendingPathComponent("events.jsonl"))
        try await log.append(.turnStarted, turn: 1)
        // The transcript's folder is a file, so its first write fails: the runner dying between the two writes.
        let blocked = directory.appendingPathComponent("transcript")
        try Data().write(to: blocked)
        let store = ThreadStore(project: Project(root: directory))
        let recorder = TurnRecorder(
            log: log, transcript: TranscriptWriter(url: blocked.appendingPathComponent("turn-1.jsonl")), turn: 1,
            sessionID: "s", provider: "claude", threadID: "t", store: store, notify: { _ in })

        await #expect(throws: (any Error).self) {
            try await recorder.record(.line(#"{"type":"result","permission_denials":[]}"#), activity: [])
        }
        await log.close()
        let events = try EventLogReader.read(at: directory.appendingPathComponent("events.jsonl")).events
        #expect(events.contains { $0.kind == .claude && $0.data["type"] == "result" }, "denials are derived from it")
    }
}
