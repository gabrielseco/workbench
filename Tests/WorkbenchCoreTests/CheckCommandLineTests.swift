import Foundation
import Testing

@testable import WorkbenchCore

// MARK: checks through the real CLI

@Suite struct CheckCommandLineTests {
    private func cli(_ arguments: [String], in fx: RunnerFixture) throws -> ProcessRun {
        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: arguments,
            environment: [
                "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "FAKE_CLAUDE": "",
            ],
            workingDirectory: fx.repo, timeout: 120)
        spawn.killGrace = 30
        // As in CrashRecoveryTests: this runner only watches the CLI and must not sweep what it leaves.
        spawn.snapshotInterval = 3600
        return try ProcessRunner.start(spawn)
    }

    private func output(of run: ProcessRun) async -> (lines: [String], exit: ProcessExit?) {
        var lines: [String] = []
        var exit: ProcessExit?
        for await event in run.events {
            if case .line(let line) = event { lines.append(line) }
            if case .exited(let e) = event { exit = e }
        }
        return (lines, exit)
    }

    @Test func runPrintsTheCheckAndLogShowsOneLineForIt() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(try script.write("echo checked\nexit 1"))
        let id = try await fx.approvedThread()

        let run = await output(of: try cli(["run"], in: fx))
        #expect(run.exit?.termination == .exited(0), "the exit status is still the turn's")
        #expect(run.lines.contains { $0.hasPrefix("check failed (exit 1)") }, "\(run.lines)")
        #expect(try fx.checkRuns(id).count == 1)

        let log = await output(of: try cli(["log"], in: fx))
        #expect(log.lines.filter { $0.contains("check") && !$0.contains("claude:") }.count == 1, "\(log.lines)")
        #expect(log.lines.contains { $0.hasSuffix("check failed (exit 1)  0s") }, "\(log.lines)")

        let status = await output(of: try cli(["status"], in: fx))
        #expect(status.lines.contains("check:     failed"), "\(status.lines)")
    }

    @Test func aRunnerKilledDuringACheckLeavesItOpenAndTheNextRunClosesIt() async throws {
        let script = try CheckScript()
        // Hangs the first time only, so the run that recovers can finish its own check.
        let body = """
            if [ -e \(script.path("seen")) ]; then echo second; exit 0; fi
            touch \(script.path("seen"))
            echo $$ > \(script.path("pid"))
            touch \(script.path("ready"))
            exec sleep 300
            """
        let fx = try await RunnerFixture.checking(try script.write(body))
        let id = try await fx.approvedThread()

        let cli = try cli(["run"], in: fx)
        #expect(await script.waitFor("ready"), "the check should be running")
        let check = try script.pid("pid")
        defer { kill(check, SIGKILL) }

        // The runner dies without a chance to record anything. The check is in its own process group.
        kill(cli.pid, SIGKILL)
        for await event in cli.events { if case .exited = event { break } }
        #expect(FakeClaude.alive(check), "the check outlives its SIGKILLed runner")
        let open = try fx.contents(id)
        #expect(open.isHealthy)
        #expect(open.openTurn == nil)
        #expect(open.openCheck == 1, "the check is left open in the log")

        let notices = NoticeBox()
        let report = try await fx.runner(id, notices: notices).run(fx.options(feedback: "carry on"))
        #expect(report.result == .succeeded)
        #expect(report.check?.result == .passed)

        let ran = try fx.checkRuns(id)
        #expect(ran.map { $0.data["result"]?.stringValue } == ["interrupted", "passed"])
        #expect(ran[0].data["synthetic"] == true)
        #expect(ran.map(\.turn) == [1, 2])
        #expect(try fx.checkStarts(id).count == 2, "one check.ran for every check.started")
        #expect(notices.all.contains { if case .recoveredOrphanedCheck(1) = $0 { true } else { false } })
        #expect(await FakeClaude.waitUntilGone(check), "what the dead runner left running is swept")
        #expect(try fx.contents(id).isHealthy)
        #expect(try fx.checkOutput(id, turn: 2) == "second\n")
    }

    @Test func workbenchStopDuringACheckRecordsItAsStopped() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(
            try script.write("touch \(script.path("ready"))\nsleep 300"))
        let id = try await fx.approvedThread()

        let cli = try cli(["run"], in: fx)
        #expect(await script.waitFor("ready"))
        #expect(fx.service.requestStop(id: id) == .signalled(pid: cli.pid))
        let run = await output(of: cli)

        #expect(run.exit?.cause == .natural, "the CLI ended by itself after recording the stop")
        #expect(try fx.checkStarts(id).count == 1)
        #expect(try fx.checkRuns(id).map { $0.data["result"]?.stringValue } == ["stopped"])
        #expect(ended(try fx.events(id)).map { $0.data["result"]?.stringValue } == ["succeeded"])
        #expect(try fx.contents(id).isHealthy)
    }
}
