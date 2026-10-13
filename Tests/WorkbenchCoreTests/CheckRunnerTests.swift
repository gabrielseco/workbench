import Foundation
import Testing

@testable import WorkbenchCore

// MARK: the runner on its own

private struct CheckDir {
    let dir: URL
    var worktree: URL { dir.appendingPathComponent("wt") }
    var logURL: URL { dir.appendingPathComponent("out/turn-1.log") }
    let environment = ["PATH": "/usr/bin:/bin"]

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-check-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    func script(_ name: String, _ body: String) throws {
        let url = worktree.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func run(
        _ command: String, timeout: TimeInterval = 20, killGrace: TimeInterval = 1, maxOutput: Int = 1 << 20
    ) async -> CheckOutcome {
        await CheckRunner.run(
            command: command, worktree: worktree, environment: environment, timeout: timeout,
            killGrace: killGrace, maxOutputBytes: maxOutput, logURL: logURL, outputRef: "checks/turn-1.log")
    }

    var output: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
}

@Suite struct CheckRunnerTests {
    @Test func passingCheckKeepsBothStreamsInOrder() async throws {
        let d = try CheckDir()
        try d.script("check.sh", "echo one; echo two >&2; echo three; pwd")
        let outcome = await d.run("./check.sh")
        #expect(outcome.result == .passed)
        #expect(outcome.exitCode == 0)
        #expect(outcome.outputRef == "checks/turn-1.log")
        #expect(outcome.durationMs >= 0)
        let lines = d.output.split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(3)) == ["one", "two", "three"])
        #expect(lines.last?.hasSuffix("/wt") == true, "it ran in the worktree")
    }

    @Test func failingCheckKeepsItsExitCodeAndOutput() async throws {
        let d = try CheckDir()
        try d.script("check.sh", "echo broken >&2; exit 3")
        let outcome = await d.run("./check.sh")
        #expect(outcome.result == .failed)
        #expect(outcome.exitCode == 3)
        #expect(d.output == "broken\n")
    }

    @Test func theCommandTextIsNeverInterpretedByAShell() async throws {
        let d = try CheckDir()
        try d.script("check.sh", "echo \"$# [$1]\"")
        let outcome = await d.run("./check.sh $HOME")
        #expect(outcome.passed)
        #expect(d.output == "1 [$HOME]\n")
    }

    @Test func timeoutKillsTheCommandAndItsChildren() async throws {
        let d = try CheckDir()
        let pidFile = FakeClaude.scratch("check-child.pid")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        try d.script("check.sh", "sleep 60 & echo $! > \(pidFile); echo started; wait")
        let started = Date()
        let outcome = await d.run("./check.sh", timeout: 1)
        #expect(outcome.result == .timedOut)
        #expect(Date().timeIntervalSince(started) < 15)
        let child = try #require(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await FakeClaude.waitUntilGone(child, within: 5), "the child must not outlive the check")
        #expect(d.output.contains("started"))
    }

    @Test func aCommandThatIgnoresSigtermIsStillKilled() async throws {
        let d = try CheckDir()
        try d.script("check.sh", "trap '' TERM; while :; do sleep 1; done")
        let started = Date()
        let outcome = await d.run("./check.sh", timeout: 0.5, killGrace: 0.5)
        #expect(outcome.result == .timedOut)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func hugeOutputIsCappedWithAMarkerAndDoesNotBlock() async throws {
        let d = try CheckDir()
        try d.script("check.sh", "yes 0123456789abcdef | head -n 400000; exit 1")
        let cap = 64 << 10
        let outcome = await d.run("./check.sh", maxOutput: cap)
        #expect(outcome.result == .failed)
        #expect(outcome.outputTruncated)
        let size = (try FileManager.default.attributesOfItem(atPath: d.logURL.path)[.size] as? Int) ?? 0
        #expect(size < cap + 4096)
        #expect(d.output.contains("[output truncated at \(cap) bytes]"))
    }

    @Test func cancellingTheCallerStopsTheCheck() async throws {
        let d = try CheckDir()
        try d.script("check.sh", "sleep 60")
        let task = Task { await d.run("./check.sh") }
        try await Task.sleep(nanoseconds: 400_000_000)
        let started = Date()
        task.cancel()
        let outcome = await task.value
        #expect(outcome.result == .stopped)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func anEmptyCommandFailsWithoutCrashing() async throws {
        let d = try CheckDir()
        let outcome = await d.run("  ")
        #expect(outcome.result == .failed)
        #expect(outcome.error != nil)
    }
}

// MARK: the event rules

@Suite struct CheckEventRuleTests {
    private func log() throws -> (EventLogWriter, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-checklog-\(UUID().uuidString)/events.jsonl")
        return (try EventLogWriter.open(at: url), url)
    }

    @Test func aSecondOpenCheckAndAnUnmatchedRanAreRejected() async throws {
        let (writer, _) = try log()
        await #expect(throws: EventLogError.invalid(.checkRanWithoutStart(turn: 1, line: 0))) {
            try await writer.append(.checkRan, turn: 1, data: [:])
        }
        try await writer.append(.checkStarted, turn: 1)
        await #expect(throws: EventLogError.invalid(.checkStartedWhileOpen(turn: 1, open: 1, line: 0))) {
            try await writer.append(.checkStarted, turn: 1)
        }
        await writer.close()
    }

    @Test func anOpenCheckIsClosedAsInterruptedExactlyOnce() async throws {
        let (first, url) = try log()
        try await first.append(.checkStarted, turn: 2, data: ["command": "./check.sh"])
        await first.close()

        let second = try EventLogWriter.open(at: url)
        #expect(await second.openCheck == 2)
        let recovered = try #require(try await second.recoverOrphanedCheck())
        #expect(recovered.kind == .checkRan)
        #expect(recovered.turn == 2)
        #expect(recovered.data["result"]?.stringValue == "interrupted")
        #expect(recovered.data["synthetic"] == true)
        #expect(try await second.recoverOrphanedCheck() == nil)
        await second.close()
        #expect(try EventLogReader.read(at: url).isHealthy)
    }
}

// MARK: inside a run

/// A repository whose committed `check.sh` is the project's check, so the worktree has it.
private func checkFixture(script: String, command: String = "./check.sh") async throws -> (RunnerFixture, String) {
    let fx = try await RunnerFixture(extraConfig: "check_command = \"\(command)\"")
    let url = fx.repo.appendingPathComponent(command.hasPrefix("./") ? String(command.dropFirst(2)) : command)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    _ = try await fx.git.run(["add", "-A"], in: fx.repo)
    _ = try await fx.git.run(["commit", "-q", "-m", "add check"], in: fx.repo)
    return (fx, try await fx.approvedThread())
}

private func waitForFile(_ path: String, timeout: TimeInterval = 20) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

@Suite struct CheckInRunTests {
    @Test func aTurnIsFollowedByARecordedCheck() async throws {
        let (fx, id) = try await checkFixture(script: "echo hello from check; echo warn >&2")
        let notices = NoticeBox()
        let report = try await fx.runner(id, notices: notices).run(fx.options("stream-events=1"))
        #expect(report.result == .succeeded)

        let events = try fx.events(id)
        #expect(events.map(\.kind.rawValue).suffix(3) == ["turn.ended", "check.started", "check.ran"])
        let ran = try #require(events.last)
        #expect(ran.turn == 1)
        #expect(ran.data["result"]?.stringValue == "passed")
        #expect(ran.data["exit_code"] == .int(0))
        #expect(ran.data["command"]?.stringValue == "./check.sh")
        #expect(ran.data["output_ref"]?.stringValue == "checks/turn-1.log")
        #expect(ran.data["duration_ms"]?.intValue != nil)
        let output = try String(contentsOf: fx.project.checkLogURL(id, turn: 1), encoding: .utf8)
        #expect(output == "hello from check\nwarn\n")
        #expect(try fx.contents(id).isHealthy)
        #expect(
            notices.all.contains { if case .checkRan(let o) = $0 { o.passed } else { false } })
    }

    @Test func aFailedTurnIsStillChecked() async throws {
        let (fx, id) = try await checkFixture(script: "exit 1")
        let report = try await fx.runner(id).run(fx.options("exit=2"))
        #expect(report.result == .failed)
        let ran = try #require(try fx.events(id).last { $0.kind == .checkRan })
        #expect(ran.data["result"]?.stringValue == "failed")
        #expect(ran.data["exit_code"] == .int(1))
    }

    @Test func nothingRunsWithoutACheckCommand() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let kinds = try fx.kinds(id)
        #expect(!kinds.contains("check.started"))
        #expect(!kinds.contains("check.ran"))
    }

    @Test func theConfiguredCommandRunsWhateverElseTheWorktreeHolds() async throws {
        let fx = try await RunnerFixture(extraConfig: "check_command = \"./check.sh\"")
        let files = [("check.sh", "echo real"), ("scripts/check.sh", "echo decoy"), ("Makefile", "check:\n\techo decoy")]
        for (name, body) in files {
            let url = fx.repo.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "scripts"], in: fx.repo)
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let output = try String(contentsOf: fx.project.checkLogURL(id, turn: 1), encoding: .utf8)
        #expect(output == "real\n")
    }

    @Test func aStoppedTurnIsNotChecked() async throws {
        let (fx, id) = try await checkFixture(script: "echo should not run")
        let ready = FakeClaude.scratch("ready-stop")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        let runner = fx.runner(id)
        let options = fx.options("ready=\(ready),hang-after=1")
        let running = Task { try await runner.run(options) }
        #expect(await waitForFile(ready))
        await runner.stop()
        let report = try await running.value
        #expect(report.result == .stopped)
        #expect(!(try fx.kinds(id)).contains("check.started"))
    }

    @Test func stoppingDuringACheckRecordsOneStoppedCheck() async throws {
        let ready = FakeClaude.scratch("ready-check")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        let (fx, id) = try await checkFixture(script: "touch \(ready); sleep 60")
        let runner = fx.runner(id)
        let options = fx.options("stream-events=1")
        let running = Task { try await runner.run(options) }
        #expect(await waitForFile(ready))
        await runner.stop()
        let report = try await running.value
        #expect(report.result == .succeeded, "the turn itself had finished")

        let events = try fx.events(id)
        #expect(events.filter { $0.kind == .checkStarted }.count == 1)
        let ran = events.filter { $0.kind == .checkRan }
        #expect(ran.count == 1)
        #expect(ran.first?.data["result"]?.stringValue == "stopped")
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func aCheckLeftOpenIsClosedBeforeTheNextTurn() async throws {
        let (fx, id) = try await checkFixture(script: "echo ok")
        let writer = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await writer.append(.checkStarted, turn: 1, data: ["command": "./check.sh"])
        await writer.close()

        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let results = try fx.events(id).filter { $0.kind == .checkRan }
            .map { $0.data["result"]?.stringValue }
        #expect(results == ["interrupted", "passed"])
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func logFormatShowsOneLinePerCheck() {
        #expect(LogFormatter.describeCheck(result: "passed", exit: 0) == "check passed")
        #expect(LogFormatter.describeCheck(result: "failed", exit: 3) == "check failed (exit 3)")
        #expect(LogFormatter.describeCheck(result: "timed_out", exit: nil) == "check timed out")
        #expect(LogFormatter.describeCheck(result: "interrupted", exit: nil) == "check interrupted")
    }
}

// MARK: a real runner, killed mid-check

@Suite struct CheckCrashRecoveryTests {
    @Test func aKilledRunnerLeavesAnOpenCheckThatTheNextRunClosesAndSweeps() async throws {
        let ready = FakeClaude.scratch("check-ready")
        let pidFile = FakeClaude.scratch("check-pid")
        defer {
            try? FileManager.default.removeItem(atPath: ready)
            try? FileManager.default.removeItem(atPath: pidFile)
        }
        // The first run's check hangs; the script is rewritten below so the second one passes.
        let (fx, id) = try await checkFixture(script: "echo $$ > \(pidFile); touch \(ready); sleep 120")

        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: ["run"],
            environment: [
                "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                "FAKE_CLAUDE": "stream-events=1",
            ],
            workingDirectory: fx.repo, timeout: 120)
        spawn.killGrace = 30
        spawn.snapshotInterval = 3600  // this watcher must not track what the CLI starts
        let cli = try ProcessRunner.start(spawn)
        #expect(await waitForFile(ready), "the check should be running inside the worktree")
        let checkPID = try #require(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(checkPID, SIGKILL) }

        kill(cli.pid, SIGKILL)
        for await event in cli.events { if case .exited = event { break } }
        #expect(FakeClaude.alive(checkPID), "the check outlives its SIGKILLed runner")
        let open = try fx.contents(id)
        #expect(open.events.last?.kind == .checkStarted, "the check is left open in the log")

        // The next run: closes the check as interrupted, sweeps what it left, runs a new turn and check.
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "#!/bin/sh\necho second\n".write(
            to: worktree.appendingPathComponent("check.sh"), atomically: true, encoding: .utf8)
        let report = try await fx.runner(id).run(fx.options("stream-events=1", feedback: "again"))
        #expect(report.result == .succeeded)

        let results = try fx.events(id).filter { $0.kind == .checkRan }.map { $0.data["result"]?.stringValue }
        #expect(results == ["interrupted", "passed"])
        #expect(try fx.contents(id).isHealthy)
        #expect(await FakeClaude.waitUntilGone(checkPID), "the dead runner's check is swept")
    }
}
