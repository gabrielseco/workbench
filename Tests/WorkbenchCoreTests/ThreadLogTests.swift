import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ThreadLogTests {
    private func log(in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("events.jsonl")
        let writer = try EventLogWriter.open(at: url)
        try await writer.append(.threadCreated)
        try await writer.append(.turnStarted, turn: 1)
        _ = try await writer.appendClaudeLine(#"{"type":"system","subtype":"init"}"#, turn: 1)
        _ = try await writer.appendClaudeLine(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#, turn: 1)
        _ = try await writer.appendClaudeLine(#"{"type":"stream_event"}"#, turn: 1)
        _ = try await writer.appendClaudeLine("not json", turn: 1)
        try await writer.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        await writer.close()
        return url
    }

    @Test func aLegacyLogReadsAsEventsWithTheClaudeLinesAsTranscript() async throws {
        let directory = Scratch.url("threadlog")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try await log(in: directory)
        let threadLog = try ThreadLog.read(at: url)
        let events = threadLog.contents.events

        #expect(threadLog.entries.count == events.count, "every stored line is one entry, in order")
        for (entry, event) in zip(threadLog.entries, events) {
            switch entry {
            case .event(let found):
                #expect(found == event && event.kind != .claude)
            case .transcript(let line):
                #expect(event.kind == .claude)
                #expect(line == TranscriptLine(turn: event.turn, ts: event.ts, seq: event.seq, data: event.data))
            }
            // What `log` printed for the event is what it prints for the entry.
            #expect(LogFormatter.describe(entry) == LogFormatter.describe(event))
        }
        #expect(threadLog.entries.filter { if case .transcript = $0 { true } else { false } }.count == 4)
    }

    @Test func aTranscriptLineFromAnythingButAClaudeEventIsNil() {
        let event = Event(seq: 1, ts: "2026-10-24T10:00:00.000Z", turn: 0, kind: .threadCreated, data: [:])
        #expect(TranscriptLine(event: event) == nil)
    }

    @Test func aLineKeptOutsideTheLogHasNoSeqAndIsDescribedAllTheSame() {
        let data: JSONValue = ["type": "system", "subtype": "init"]
        let inLog = TranscriptLine(turn: 2, ts: "2026-10-24T10:00:00.000Z", seq: 7, data: data)
        let elsewhere = TranscriptLine(turn: 2, ts: "2026-10-24T10:00:00.000Z", seq: nil, data: data)
        let withSeq = LogFormatter.describe(.transcript(inLog))
        let without = LogFormatter.describe(.transcript(elsewhere))
        #expect(withSeq.hasSuffix("t2  session started") && withSeq.hasPrefix("   7  "))
        #expect(without.hasSuffix("t2  session started") && without.hasPrefix("   -  "))
    }
}
