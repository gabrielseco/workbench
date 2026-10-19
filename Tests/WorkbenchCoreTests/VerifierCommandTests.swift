import Foundation
import Testing

@testable import WorkbenchCore

private struct Out {
    var code: Int32?
    var stdout: [String]
    var stderr: String
    var text: String { (stdout + [stderr]).joined(separator: "\n") }
}

private func cli(_ arguments: [String], in fx: RunnerFixture, fake: String = "") async throws -> Out {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "FAKE_CLAUDE": fake,
        ],
        workingDirectory: fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in try ProcessRunner.start(spawn).events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return Out(code: code, stdout: lines, stderr: exit?.stderrTail ?? "")
}

@Suite struct VerifierCommandTests {
    @Test func aProjectWithoutAVerifierSaysSoAndExitsAsARefusal() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let out = try await cli(["verifier"], in: fx)
        #expect(out.code == 6 && out.text.contains("no [verifier]"), "\(out.text)")
    }

    @Test func theCommandVerifiesOnceAndAgainOnRequestThroughTheBinary() async throws {
        let v = try await VerifierFixture()
        var out = try await cli(["verifier"], in: v.fx, fake: "proof=shot.png")
        #expect(out.code == 0, "\(out.text)")
        #expect(out.text.contains("verifying \(v.id)") && out.text.contains("verifier finished for turn 1"), "\(out.text)")
        #expect(out.text.contains("proof: shot.png") && out.text.contains("advisory only"), "\(out.text)")

        out = try await cli(["verifier"], in: v.fx)
        #expect(out.code == 6 && out.text.contains("verified already") && out.text.contains("--again"), "\(out.text)")

        out = try await cli(["verifier", "--again"], in: v.fx, fake: "error-result")
        #expect(out.code == 1 && out.text.contains("verifier did not finish for turn 1"), "\(out.text)")
        try v.expectPaired(2)

        out = try await cli(["log", v.id], in: v.fx)
        #expect(out.text.contains("verifier started: .claude/skills/verify/SKILL.md"), "\(out.text)")
        #expect(out.text.contains("verifier finished") && out.text.contains("verifier did not finish"), "\(out.text)")
    }

    @Test func aStopSignalReachesTheVerifierAndItStillEnds() async throws {
        let v = try await VerifierFixture()
        let ready = FakeClaude.scratch("verifier-ready")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: ["verifier"],
            environment: [
                "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                "FAKE_CLAUDE": "hang-after=1,ready=\(ready)",
            ],
            workingDirectory: v.fx.repo, timeout: 60)
        spawn.snapshotInterval = 3600
        let run = try ProcessRunner.start(spawn)
        let deadline = Date().addingTimeInterval(Patience.limit)
        while !FileManager.default.fileExists(atPath: ready), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try #require(FileManager.default.fileExists(atPath: ready), "the verifier never started")
        let stop = try await cli(["stop"], in: v.fx)
        #expect(stop.code == 0, "\(stop.text)")
        var exit: ProcessExit?
        for await event in run.events { if case .exited(let e) = event { exit = e } }
        #expect(exit != nil)
        try v.expectPaired(1)
        #expect(try v.verifierEvents().last?.data["reason"]?.stringValue == "the verifier was stopped")
    }
}

@Suite struct VerifierLogTests {
    @Test func anOpenVerifierIsClosedOnceWithItsTurn() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wb-vlog-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try EventLogWriter.open(at: url)
        #expect(await log.hasOpenVerifier == false)
        #expect(try await log.recoverOrphanedVerifier() == nil)
        try await log.append(.verifierStarted, turn: 3, data: ["argv": ["claude"]])
        #expect(await log.hasOpenVerifier)
        let closed = try #require(try await log.recoverOrphanedVerifier())
        #expect(closed.kind == .verifierEnded && closed.turn == 3)
        #expect(closed.data["ok"] == false && closed.data["synthetic"] == true && closed.data["reason"] == "interrupted")
        #expect(await log.hasOpenVerifier == false)
        #expect(try await log.recoverOrphanedVerifier() == nil)
        await log.close()

        // Reopened, the same state is read back from the file.
        let again = try EventLogWriter.open(at: url)
        #expect(await again.hasOpenVerifier == false)
        await again.close()
    }

    @Test func aStartWithoutAnEndIsStillOpenAfterAReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wb-vlog-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try EventLogWriter.open(at: url)
        try await log.append(.verifierStarted, turn: 1, data: [:])
        await log.close()
        let again = try EventLogWriter.open(at: url)
        #expect(await again.hasOpenVerifier)
        await again.close()
    }

    @Test(arguments: [
        // (event, turnSucceeded, checks, verifies, verifiers, checkPassed, ends)
        ("check.ran", true, true, false, true, true, false),
        ("check.ran", true, true, false, false, true, true),
        ("check.ran", true, true, false, true, false, true),
        ("verify.ended", true, true, true, true, true, false),
        ("verify.ended", true, true, true, true, false, true),
        ("verify.ended", true, true, true, false, true, true),
        ("turn.ended", true, false, false, true, true, false),
        ("turn.ended", false, false, false, true, true, true),
        ("verifier.ended", true, true, false, true, true, true),
        ("verifier.skipped", true, true, false, true, true, true),
    ])
    func followingALogWaitsForTheVerifierOnlyWhenOneWillRun(
        kind: String, succeeded: Bool, checks: Bool, verifies: Bool, verifiers: Bool, checkPassed: Bool, ends: Bool
    ) {
        let result = kind == "check.ran" ? (checkPassed ? "passed" : "failed") : (succeeded ? "succeeded" : "failed")
        let event = Event(seq: 9, ts: "t", turn: 1, kind: EventKind(rawValue: kind), data: ["result": .string(result)])
        #expect(
            LogFormatter.followEnds(
                event, sawStart: true, checks: checks, verifies: verifies, turnSucceeded: succeeded, verifiers: verifiers,
                checkPassed: checkPassed) == ends)
    }

    @Test func theLogFormatterNamesTheVerifierEvents() {
        let skill = ".claude/skills/verify/SKILL.md"
        let started = Event(seq: 1, ts: "2026-10-19T10:00:00Z", turn: 1, kind: .verifierStarted, data: ["skill": .string(skill)])
        #expect(LogFormatter.describe(started).contains("verifier started: .claude/skills/verify/SKILL.md"))
        let failed = Event(
            seq: 2, ts: "2026-10-19T10:00:09Z", turn: 1, kind: .verifierEnded,
            data: ["ok": false, "reason": "stopped at the budget ($1)", "duration_ms": 9000, "files": ["x"]])
        let line = LogFormatter.describe(failed)
        #expect(line.contains("verifier did not finish (stopped at the budget ($1))") && line.contains("9s"), "\(line)")
        #expect(line.contains("1 proof file(s)"))
        let skipped = Event(
            seq: 3, ts: "2026-10-19T10:00:09Z", turn: 1, kind: .verifierSkipped,
            data: ["reason": "the turn left no change to look at"])
        #expect(LogFormatter.describe(skipped).contains("verifier skipped: the turn left no change to look at"))
    }
}
