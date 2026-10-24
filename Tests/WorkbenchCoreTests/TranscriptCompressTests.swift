import Foundation
import Testing

@testable import WorkbenchCore

private struct Turn {
    var directory: URL
    var plain: URL
    var original: [TranscriptLine]
}

private func finishedTurn(lines: Int = 40) throws -> Turn {
    let directory = Scratch.url("compress")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let plain = TranscriptFile.url(in: directory, turn: 1)
    let writer = TranscriptWriter(url: plain)
    for n in 0..<lines { try writer.append(#"{"type":"assistant","n":\#(n)}"#) }
    writer.close()
    return Turn(directory: directory, plain: plain, original: TranscriptFile.lines(at: plain, turn: 1))
}

@Suite struct TranscriptCompressTests {
    @Test func aFinishedTurnIsGzippedAndReadsTheSame() throws {
        let turn = try finishedTurn()
        let (plain, original) = (turn.plain, turn.original)
        let before = try #require(TranscriptFile.summary(at: plain))

        #expect(TranscriptFile.compress(plain))
        #expect(!FileManager.default.fileExists(atPath: plain.path), "the plain file is gone")
        #expect(FileManager.default.fileExists(atPath: TranscriptFile.compressedURL(plain).path))
        #expect(!FileManager.default.fileExists(atPath: TranscriptFile.compressedURL(plain).path + ".partial"))
        #expect(TranscriptFile.exists(plain))
        #expect(TranscriptFile.lines(at: plain, turn: 1) == original)
        #expect(TranscriptFile.summary(at: plain) == before, "the counts turn.ended recorded still hold")
        // From an offset too: a reader that followed the plain file goes on in the compressed one.
        let first = TranscriptFile.read(at: plain)
        #expect(first.lines.count == 40 && TranscriptFile.read(at: plain, from: first.offset).lines.isEmpty)
    }

    @Test func aReaderHalfWayThroughThePlainFileGoesOnInTheCompressedOne() throws {
        let turn = try finishedTurn()
        let (plain, original) = (turn.plain, turn.original)
        // It has seen the first line only, by byte offset, as `log -f` does.
        let head = try #require(Data(contentsOf: plain).firstIndex(of: 0x0A))
        #expect(TranscriptFile.compress(plain))

        let rest = TranscriptFile.read(at: plain, from: head + 1)
        #expect(rest.lines.count == original.count - 1)
        #expect(rest.lines.map(\.data) == original.dropFirst().map(\.data))
    }

    @Test func aFailureLeavesThePlainFileWhole() throws {
        let turn = try finishedTurn()
        let (plain, original) = (turn.plain, turn.original)
        // Something is in the way of the temporary file: the compressed copy cannot be made.
        try FileManager.default.createDirectory(
            at: TranscriptFile.compressedURL(plain).appendingPathExtension("partial"), withIntermediateDirectories: true)
        #expect(!TranscriptFile.compress(plain))
        #expect(FileManager.default.fileExists(atPath: plain.path))
        #expect(TranscriptFile.lines(at: plain, turn: 1) == original)
    }

    @Test func aFileOverTheLimitStaysPlain() throws {
        let turn = try finishedTurn()
        let (plain, original) = (turn.plain, turn.original)
        #expect(!TranscriptFile.compress(plain, limit: 10))
        #expect(FileManager.default.fileExists(atPath: plain.path))
        #expect(!FileManager.default.fileExists(atPath: TranscriptFile.compressedURL(plain).path))
        #expect(TranscriptFile.lines(at: plain, turn: 1) == original)
    }

    @Test func compressingTwiceOrNothingIsHarmless() throws {
        let turn = try finishedTurn()
        let (plain, original) = (turn.plain, turn.original)
        #expect(TranscriptFile.compress(plain))
        #expect(TranscriptFile.compress(plain), "already compressed")
        #expect(TranscriptFile.lines(at: plain, turn: 1) == original)
        #expect(!TranscriptFile.compress(Scratch.url("none").appendingPathComponent("turn-9.jsonl")))
    }

    @Test func recoveringATurnGzipsItsTranscriptAfterCountingIt() async throws {
        let turn = try finishedTurn(lines: 3)
        let plain = turn.plain
        let log = try EventLogWriter.open(at: turn.directory.appendingPathComponent("events.jsonl"))
        try await log.append(.turnStarted, turn: 1)
        let ended = try #require(try await log.recoverOrphanedTurn())
        #expect(ended.data["transcript"]?["lines"]?.intValue == 3)
        #expect(!FileManager.default.fileExists(atPath: plain.path) && TranscriptFile.exists(plain))
        await log.close()
    }
}
