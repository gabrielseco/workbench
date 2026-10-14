import Foundation
import Testing

@testable import WorkbenchCore

private func setupFixture(_ script: CheckScript, body: String) async throws -> RunnerFixture {
    let path = try script.write(body, name: "setup.sh")
    return try await RunnerFixture(extraConfig: "setup_command = \"\(path)\"")
}

private func failure(_ block: () async throws -> some Any) async -> RunnerError? {
    do { _ = try await block() } catch let error as RunnerError { return error } catch {}
    return nil
}

@Suite struct SetupTests {
    @Test func aPassingSetupRunsInTheNewWorktreeBeforeTheFirstTurn() async throws {
        let script = try CheckScript()
        let fx = try await setupFixture(script, body: "echo installing\ntouch \"$PWD/installed\"")
        let id = try await fx.approvedThread()
        let notices = NoticeBox()
        let report = try await fx.runner(id, notices: notices).run(fx.options())

        #expect(report.result == .succeeded)
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("installed").path))
        let kinds = try fx.kinds(id)
        let setup = try #require(kinds.firstIndex(of: "setup.ran"))
        let turn = try #require(kinds.firstIndex(of: "turn.started"))
        #expect(try #require(kinds.firstIndex(of: "worktree.created")) < setup && setup < turn)
        let event = try #require(try fx.events(id).first { $0.kind == .setupRan })
        #expect(event.turn == 0)
        #expect(event.data["result"]?.stringValue == "passed")
        #expect(event.data["exit_code"]?.intValue == 0)
        #expect(event.data["output_ref"]?.stringValue == "setup.log")
        #expect(try String(contentsOf: fx.project.setupOutputURL(id), encoding: .utf8) == "installing\n")
        #expect(try fx.contents(id).isHealthy)
        #expect(notices.all.contains { if case .setupRan(let s) = $0 { s.result == .passed } else { false } })
    }

    @Test func aFailingSetupStopsTheStartBeforeATurnAndShowsItsOutput() async throws {
        let script = try CheckScript()
        let fx = try await setupFixture(script, body: "echo installing\necho boom >&2\nexit 3")
        let id = try await fx.approvedThread()
        let error = await failure { try await fx.runner(id).run(fx.options()) }

        guard case .setupFailed(_, let how, let output, _)? = error else {
            Issue.record("expected setupFailed, got \(String(describing: error))")
            return
        }
        #expect(how == "failed (exit 3)")
        #expect(output.contains("boom") && output.contains("installing"))
        #expect("\(error!)".contains("env_pass"), "a failed setup says where a dropped variable goes")
        let kinds = try fx.kinds(id)
        #expect(!kinds.contains("turn.started"))
        #expect(kinds.contains("setup.ran"))
        #expect(try fx.contents(id).isHealthy)
        #expect(fx.contentsOfRunnerFile(id) == nil, "the runner file is gone: nothing is left running")
        #expect(FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.appendingPathComponent(id).path))
    }

    @Test func aFailedSetupIsTriedAgainByTheNextRunAndThenTheTurnStarts() async throws {
        let script = try CheckScript()
        let fx = try await setupFixture(script, body: "exit 1")
        let id = try await fx.approvedThread()
        #expect(await failure { try await fx.runner(id).run(fx.options()) } != nil)

        try script.write("touch \"$PWD/installed\"", name: "setup.sh")
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.result == .succeeded)
        let results = try fx.events(id).filter { $0.kind == .setupRan }.map { $0.data["result"]?.stringValue }
        #expect(results == ["failed", "passed"])
    }

    @Test func aSendBackDoesNotRunTheSetupAgain() async throws {
        let script = try CheckScript()
        let fx = try await setupFixture(script, body: "echo run >> \(script.path("count"))")
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        _ = try await fx.runner(id).run(fx.options(feedback: "more"))

        #expect(try String(contentsOfFile: script.path("count"), encoding: .utf8) == "run\n")
        #expect(try fx.events(id).filter { $0.kind == .setupRan }.count == 1)
    }

    @Test func aSetupThatCannotBeFoundIsAFailureNotACrash() async throws {
        let name = "no-such-setup-\(UUID().uuidString.prefix(8).lowercased())"
        let fx = try await RunnerFixture(extraConfig: "setup_command = \"\(name)\"")
        let id = try await fx.approvedThread()
        let error = await failure { try await fx.runner(id).run(fx.options()) }
        guard case .setupFailed(_, _, let output, _)? = error else {
            Issue.record("expected setupFailed, got \(String(describing: error))")
            return
        }
        #expect(output.contains("cannot find"))
        #expect(!(try fx.kinds(id)).contains("turn.started"))
    }

    @Test func aHungSetupIsTimedOutAndLeavesNothingRunning() async throws {
        let script = try CheckScript()
        let fx = try await setupFixture(
            script, body: "sleep 300 &\necho $! > \(script.path("child"))\nwait")
        let id = try await fx.approvedThread()
        var options = fx.options()
        options.setupTimeoutOverride = 2
        let error = await failure { try await fx.runner(id).run(options) }

        guard case .setupFailed(_, let how, _, _)? = error else {
            Issue.record("expected setupFailed, got \(String(describing: error))")
            return
        }
        #expect(how == "timed out")
        #expect(!"\(error!)".contains("env_pass"), "a timeout is not an environment problem")
        let child = try script.pid("child")
        defer { kill(child, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(child))
        #expect(!(try fx.kinds(id)).contains("turn.started"))
    }

    @Test func withNoSetupCommandNothingRunsAndNothingIsWritten() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        #expect(!(try fx.kinds(id)).contains("setup.ran"))
    }

    @Test func theConfigKeyIsValidatedLikeTheCheckCommand() throws {
        func parse(_ line: String) throws -> Config {
            try Config.parse("\(line)\n[tools]\navailable = [\"Read\"]\n")
        }
        #expect(try parse("setup_command = \"mix deps.get\"").setupCommand == "mix deps.get")
        #expect(try parse("").setupCommand == nil)
        for bad in ["a && b", "a | b", "$(x)", "-rf", "", "a > b"] {
            #expect(throws: ConfigError.self, "\(bad)") { try parse("setup_command = \"\(bad)\"") }
        }
    }

    @Test func theSetupIsNotOfferedToClaude() throws {
        let config = try Config.parse(
            "setup_command = \"mix deps.get\"\n[tools]\navailable = [\"Bash\"]\nallowed = [\"Read\"]\n")
        #expect(!config.effectiveAllowedTools.contains { $0.contains("mix") })
    }

    @Test func stoppingDuringTheSetupRecordsItAsStoppedAndStartsNoTurn() async throws {
        let script = try CheckScript()
        let fx = try await setupFixture(
            script, body: "sleep 300 &\necho $! > \(script.path("child"))\ntouch \(script.path("ready"))\nwait")
        let id = try await fx.approvedThread()
        let runner = fx.runner(id)
        let options = fx.options()
        let task = Task { try await runner.run(options) }
        try #require(await script.waitFor("ready"))
        await runner.stop()
        let error = await failure { try await task.value }

        guard case .setupFailed(_, let how, _, _)? = error else {
            Issue.record("expected setupFailed, got \(String(describing: error))")
            return
        }
        #expect(how == "was stopped")
        let ran = try #require(try fx.events(id).first { $0.kind == .setupRan })
        #expect(ran.data["result"]?.stringValue == "stopped")
        #expect(!(try fx.kinds(id)).contains("turn.started"))
        let child = try script.pid("child")
        defer { kill(child, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(child))
    }

    @Test func followingTheLogEndsWhenTheSetupFails() async throws {
        let script = try CheckScript()
        let go = script.path("go")
        let fx = try await setupFixture(
            script, body: "touch \(script.path("started"))\nwhile [ ! -f \(go) ]; do sleep 0.1; done\nexit 1")
        let id = try await fx.approvedThread()
        let runner = fx.runner(id)
        let options = fx.options()
        let running = Task { try await runner.run(options) }
        try #require(await script.waitFor("started"))

        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: ["log", "--follow"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
            workingDirectory: fx.repo, timeout: 40)
        spawn.snapshotInterval = 3600
        let follower = try ProcessRunner.start(spawn)
        // The follower reads the log once, then polls; release the setup after it had time to start.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        FileManager.default.createFile(atPath: go, contents: nil)

        var exit: ProcessExit?
        for await event in follower.events { if case .exited(let e) = event { exit = e } }
        _ = await failure { try await running.value }
        #expect(exit?.termination == .exited(0), "it returned instead of waiting for ever")
        #expect(exit?.cause == .natural)
    }
}
