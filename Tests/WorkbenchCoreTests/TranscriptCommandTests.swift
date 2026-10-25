import Foundation
import Testing

@testable import WorkbenchCore

private struct Out {
    var code: Int32?
    var lines: [String]
    var stderr: String
}

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> Out {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
        workingDirectory: fx.repo, timeout: 60)
    spawn.snapshotInterval = 3600
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in try ProcessRunner.start(spawn).events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let found) = event { exit = found }
    }
    var code: Int32?
    if case .exited(let value)? = exit?.termination { code = value }
    return Out(code: code, lines: lines, stderr: exit?.stderrTail ?? "")
}

@Suite(.processGate) struct TranscriptCommandTests {
    @Test func aFinishedTurnIsGzippedAndLogTranscriptPrintsItsLinesAsStored() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())

        let plain = TranscriptFile.url(in: fx.project.threadDirectory(id), turn: 1)
        #expect(!FileManager.default.fileExists(atPath: plain.path), "gzipped when the turn ended")
        #expect(FileManager.default.fileExists(atPath: TranscriptFile.compressedURL(plain).path))
        let stored = TranscriptFile.read(at: plain).lines.map(\.rawData)
        #expect(stored.count >= 3 && stored.last?.contains("\"type\":\"result\"") == true)

        let printed = try await cli(["log", id, "--transcript"], in: fx)
        #expect(printed.code == 0 && printed.stderr.isEmpty, "\(printed)")
        #expect(printed.lines == stored, "byte for byte, nothing of Workbench's own")
        let turn = try await cli(["log", id, "--transcript", "--turn", "1"], in: fx)
        #expect(turn.lines == stored)
        let none = try await cli(["log", id, "--transcript", "--turn", "7"], in: fx)
        #expect(none.code == 0 && none.lines.isEmpty)

        // The ordinary views read the compressed file as they read the plain one.
        let log = try await cli(["log", id], in: fx)
        #expect(log.lines.contains { $0.contains("claude session") }, "the turn is read through its activity")
        let json = try await cli(["log", id, "--json"], in: fx)
        #expect(json.lines.contains { $0.contains("\"kind\":\"agent.activity\"") })
        #expect(!json.lines.contains { $0.contains("\"kind\":\"claude\"") }, "no stream line is an event any more")
    }

    @Test func aDamagedGzipIsReportedNotPrintedAsNothing() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let packed = TranscriptFile.compressedURL(TranscriptFile.url(in: fx.project.threadDirectory(id), turn: 1))
        var bytes = try Data(contentsOf: packed)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: packed)

        let printed = try await cli(["log", id, "--transcript"], in: fx)
        #expect(printed.code == 1 && printed.lines.isEmpty, "\(printed)")
        #expect(printed.stderr.contains("the transcript of turn 1 cannot be read: damaged"), "\(printed.stderr)")
        // The ordinary views do not need the file: the turn is in the log.
        let log = try await cli(["log", id], in: fx)
        #expect(log.code == 0 && log.lines.contains { $0.contains("turn ended") }, "\(log)")
        let status = try await cli(["status", id], in: fx)
        #expect(status.code == 0, "\(status)")
    }

    @Test func anOlderLogsClaudeEventsArePrintedAsTheyWereStored() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.turnStarted, turn: 1)
        try await log.appendClaudeLine(#"{"type":"system","subtype":"init","b":2,"a":1}"#, turn: 1)
        try await log.appendClaudeLine("not json {", turn: 1)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        await log.close()

        let printed = try await cli(["log", id, "--transcript"], in: fx)
        #expect(printed.lines == [#"{"type":"system","subtype":"init","b":2,"a":1}"#, #"{"invalid_json":"not json {"}"#])
    }

    @Test func theFlagsAreCheckedBeforeAnythingIsPrinted() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let followed = try await cli(["log", id, "--transcript", "-f"], in: fx)
        #expect(followed.code == 2 && followed.lines.isEmpty, "\(followed)")
        let lone = try await cli(["log", id, "--turn", "1"], in: fx)
        #expect(lone.code == 2 && lone.stderr.contains("--turn goes with --transcript"), "\(lone)")
        let bad = try await cli(["log", id, "--transcript", "--turn", "x"], in: fx)
        #expect(bad.code == 2 && bad.stderr.contains("--turn needs a turn number"), "\(bad)")
    }
}
