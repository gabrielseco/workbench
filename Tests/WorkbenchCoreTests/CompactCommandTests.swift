import Foundation
import Testing

@testable import WorkbenchCore

private struct Out {
    var code: Int32?
    var lines: [String]
    var stderr: String
    var text: String { (lines + [stderr]).joined(separator: "\n") }
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

/// An accepted thread whose log holds its stream lines, as an older Workbench wrote it.
private func endedLegacyThread(_ fx: RunnerFixture) async throws -> String {
    let id = try await fx.approvedThread()
    let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
    try await log.append(.turnStarted, turn: 1)
    for n in 0..<30 { try await log.appendClaudeLine(#"{"type":"stream_event","n":\#(n)}"#, turn: 1) }
    try await log.appendClaudeLine(#"{"type":"result","subtype":"success","permission_denials":[]}"#, turn: 1)
    try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
    try await log.append(.reviewDecision, data: ["decision": "accepted"])
    await log.close()
    return id
}

@Suite(.processGate) struct CompactCommandTests {
    @Test func compactMovesAnEndedThreadAndLeavesItsTranscriptAndStatusAsTheyWere() async throws {
        let fx = try await RunnerFixture()
        let id = try await endedLegacyThread(fx)
        let transcript = try await cli(["log", id, "--transcript"], in: fx).lines
        let status = try await cli(["status", id, "--json"], in: fx)
        let size = try Data(contentsOf: fx.project.eventsURL(id)).count

        let dry = try await cli(["compact", id, "--dry-run"], in: fx)
        #expect(dry.code == 0 && dry.text.contains("would move"), "\(dry.text)")
        #expect(try Data(contentsOf: fx.project.eventsURL(id)).count == size, "a dry run writes nothing")

        let done = try await cli(["compact", id], in: fx)
        #expect(done.code == 0 && done.text.contains("31 stream line(s) of 1 turn(s) moved"), "\(done.text)")
        #expect(try Data(contentsOf: fx.project.eventsURL(id)).count < size / 2)
        #expect(try await cli(["log", id, "--transcript"], in: fx).lines == transcript)
        // `seq` is renumbered; everything else of the thread is the same.
        let after = try await cli(["status", id, "--json"], in: fx)
        func without(_ lines: [String]) -> String {
            lines.joined().replacingOccurrences(of: #""seq":\d+"#, with: "", options: .regularExpression)
        }
        #expect(after.code == 0 && without(after.lines) == without(status.lines))

        let again = try await cli(["compact", id], in: fx)
        #expect(again.code == 0 && again.text.contains("nothing to move"), "\(again.text)")
    }

    @Test func aThreadThatHasNotEndedIsRefusedWithExit6() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.turnStarted, turn: 1)
        try await log.appendClaudeLine(#"{"type":"system"}"#, turn: 1)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        await log.close()

        let named = try await cli(["compact", id], in: fx)
        #expect(named.code == 6 && named.text.contains("has not ended"), "\(named.text)")
        let all = try await cli(["compact", "--all"], in: fx)
        #expect(all.code == 0 && all.text.contains("\(id): skipped, it has not ended"), "\(all.text)")
    }

    @Test func theArgumentsAreChecked() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        for arguments in [["compact"], ["compact", id, "--all"], ["compact", "--bogus"]] {
            let result = try await cli(arguments, in: fx)
            #expect(result.code == 2, "\(arguments): \(result.text)")
        }
        let missing = try await cli(["compact", "g-nothing-here"], in: fx)
        #expect(missing.code == 7, "\(missing.text)")
    }
}
