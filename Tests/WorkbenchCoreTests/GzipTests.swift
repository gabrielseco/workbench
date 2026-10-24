import Foundation
import Testing

@testable import WorkbenchCore

private func gzip(_ arguments: [String], input: URL) async throws -> (exit: ProcessExit?, lines: [String]) {
    let spawn = SpawnRequest(
        executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: arguments + [input.path],
        environment: ["PATH": "/usr/bin:/bin"], workingDirectory: input.deletingLastPathComponent(), timeout: 30)
    let run = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let found) = event { exit = found }
    }
    return (exit, lines)
}

@Suite(.processGate) struct GzipTests {
    private let sample = Data((0..<500).map { #"{"type":"assistant","n":\#($0),"text":"héllo"}"# + "\n" }.joined().utf8)

    @Test func whatIsCompressedComesBackAndTheSystemGzipAgrees() async throws {
        let packed = try Gzip.compress(sample)
        #expect(packed.count < sample.count / 4)
        #expect(try Gzip.decompress(packed) == sample)

        let file = Scratch.url("gz").appendingPathExtension("jsonl.gz")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try packed.write(to: file)
        let test = try await gzip(["-t"], input: file)
        #expect(test.exit?.termination == .exited(0), "gzip -t: \(test.lines)")
        let shown = try await gzip(["-dc"], input: file)
        #expect(shown.lines == String(decoding: sample, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    @Test func whatTheSystemGzipWritesIsReadToo() async throws {
        let plain = Scratch.url("gzin").appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sample.write(to: plain)
        let made = try await gzip(["-k"], input: plain)  // keeps the file, writes <name>.gz with the file's name in it
        #expect(made.exit?.termination == .exited(0))
        let packed = try Data(contentsOf: plain.appendingPathExtension("gz"))
        #expect(try Gzip.decompress(packed) == sample)
    }

    @Test func anEmptyInputAndATornOrAlteredFileAreHandled() throws {
        #expect(try Gzip.decompress(try Gzip.compress(Data())) == Data())
        let packed = try Gzip.compress(sample)
        #expect(throws: Gzip.Failure.notGzip) { try Gzip.decompress(sample) }
        #expect(throws: (any Error).self) { try Gzip.decompress(packed.prefix(packed.count / 2)) }
        var altered = packed
        altered[altered.count - 6] ^= 0xFF  // a byte of the CRC
        #expect(throws: Gzip.Failure.corrupt("checksum")) { try Gzip.decompress(altered) }
    }

    @Test func aBombIsRefusedWithoutInflatingPastTheLimit() throws {
        // 8 MiB of zeros is a few KiB gzipped; a reader that allows 1 MiB must stop at it.
        let bomb = try Gzip.compress(Data(count: 8 << 20))
        #expect(bomb.count < 20_000)
        #expect(throws: Gzip.Failure.tooLarge) { try Gzip.decompress(bomb, limit: 1 << 20) }
        #expect(try Gzip.decompress(bomb, limit: 8 << 20).count == 8 << 20, "exactly at the limit is allowed")
        #expect(throws: Gzip.Failure.tooLarge) { try Gzip.decompress(bomb, limit: (8 << 20) - 1) }
    }

    @Test func theCRCIsTheStandardOne() {
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(Gzip.crc32(Data()) == 0)
    }
}
