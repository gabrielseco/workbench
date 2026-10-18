import Foundation
import Testing

@testable import WorkbenchCore

private func options(_ extra: [String: String] = [:], grace: TimeInterval = 2) -> Doctor.Options {
    var o = Doctor.Options()
    o.environment =
        [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "FAKE_CLAUDE": "set",
            "GITHUB_TOKEN": "ghp_not_for_the_child",
        ].merging(extra) { $1 }
    o.setupTimeout = 30
    o.checkTimeout = 30
    o.verifyTimeout = 30
    o.screenRecordingGranted = { true }
    o.killGrace = grace
    return o
}

private func fixture(setup: String? = nil, check: String? = nil, verify: String? = nil, extra: String = "") async throws -> (
    RunnerFixture, CheckScript
) {
    let script = try CheckScript()
    var lines: [String] = []
    if let setup { lines.append("setup_command = \"\(try script.write(setup, name: "setup.sh"))\"") }
    if let check { lines.append("check_command = \"\(try script.write(check, name: "check.sh"))\"") }
    if let verify { lines.append("verify_command = \"\(try script.write(verify, name: "verify.sh"))\"") }
    lines.append(extra)
    return (try await RunnerFixture(extraConfig: lines.joined(separator: "\n")), script)
}

/// Nothing of doctor's is left: one worktree (the checkout), no `workbench/*` branch, no worktree directory.
private func expectClean(_ fx: RunnerFixture, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let list = try await fx.git.run(["worktree", "list", "--porcelain"], in: fx.repo).stdout
    #expect(list.components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.count == 1, "\(list)")
    let branches = try await fx.git.run(["branch", "--list", "workbench/*"], in: fx.repo).stdout
    #expect(branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(branches)")
    #expect(!FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.appendingPathComponent("doctor").path))
}

@Suite struct DoctorTests {
    @Test func aPassingSetupAndCheckRunInTheSameThrowawayWorktree() async throws {
        let (fx, _) = try await fixture(setup: "touch \"$PWD/installed\"", check: "test -f \"$PWD/installed\"")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        #expect(report.passed)
        #expect(report.setup.outcome == .passed)
        #expect(report.check.outcome == .passed)
        #expect(report.setup.durationMs != nil && report.check.durationMs != nil)
        #expect(report.base == "main")
        try await expectClean(fx)
    }

    @Test func aFailingSetupShowsItsOutputAndTheEnvHintAndSkipsTheCheck() async throws {
        let (fx, script) = try await fixture(
            setup: "echo installing\necho boom >&2\nexit 3", check: "touch \"$0.ran\"")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        #expect(!report.passed)
        #expect(report.setup.outcome == .failed(how: "failed (exit 3)"))
        #expect(report.setup.tail.contains("boom") && report.setup.tail.contains("installing"))
        #expect(report.setup.hint.contains("env_pass"))
        #expect(report.check.outcome == .skipped("setup did not pass"))
        #expect(!script.exists("check.sh.ran"), "the check did not run")
        try await expectClean(fx)
    }

    @Test func aFailingCheckShowsItsOutput() async throws {
        let (fx, _) = try await fixture(setup: "true", check: "echo 'FAIL: 2 tests'\nexit 2")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        #expect(!report.passed)
        #expect(report.setup.outcome == .passed)
        #expect(report.check.outcome == .failed(how: "failed (exit 2)"))
        #expect(report.check.tail.contains("FAIL: 2 tests"))
        try await expectClean(fx)
    }

    @Test func theChildEnvironmentIsTheThreadsAllowlistSoAMissingVariableFailsHere() async throws {
        // FIXTURE_TOKEN is in the parent environment; only `env_pass` lets it through.
        let body = "test -n \"$FIXTURE_TOKEN\" && test -z \"$GITHUB_TOKEN\""
        let (fx, _) = try await fixture(check: body)
        let parent = options(["FIXTURE_TOKEN": "yes"])

        let without = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: parent)
        #expect(without.check.outcome == .failed(how: "failed (exit 1)"))

        var config = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        config = config.replacingOccurrences(of: "env_pass = [\"FAKE_CLAUDE\"]", with: "env_pass = [\"FIXTURE_TOKEN\"]")
        try config.write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let with = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: parent)
        #expect(with.check.outcome == .passed)
    }

    @Test func anUndeclaredStepIsReportedAndIsNotAFailure() async throws {
        let (fx, _) = try await fixture(setup: "true")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.passed)
        #expect(report.setup.outcome == .passed)
        #expect(report.check.outcome == .notDeclared)
        #expect(report.check.command == nil)

        let (bare, _) = try await fixture()
        let nothing = try await Doctor(project: bare.project, git: bare.git).run(base: "main", options: options())
        #expect(nothing.passed)
        #expect(nothing.setup.outcome == .notDeclared && nothing.check.outcome == .notDeclared)
        try await expectClean(bare)
    }

    @Test func itReportsClaudeModelAndWhatARunMayCall() async throws {
        let (fx, script) = try await fixture(check: "true", extra: "model = \"opus\"")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.claude == FakeClaude.executable.path)
        #expect(report.model == "opus")
        #expect(report.bashAvailable)
        #expect(report.checkPattern == "Bash(\(script.path("check.sh")):*)")

        var config = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        config = config.replacingOccurrences(of: FakeClaude.executable.path, with: "no-such-claude-here")
        config = config.replacingOccurrences(of: "model = \"opus\"\n", with: "")
        config = config.replacingOccurrences(of: "available = [\"Read\", \"Edit\", \"Bash\"]", with: "available = [\"Read\"]")
        try config.write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let other = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(other.claude == nil && other.claudePath == "no-such-claude-here")
        #expect(other.model == nil)
        #expect(!other.bashAvailable)
    }

    @Test func aLeftoverWorktreeFromACrashedRunIsReplaced() async throws {
        let (fx, _) = try await fixture(check: "true")
        let manager = WorktreeManager(repoRoot: fx.repo, git: fx.git)
        _ = try await manager.create(threadID: Doctor.worktreeID, base: "main")

        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.passed)
        try await expectClean(fx)
    }

    @Test func stoppingEndsTheStepSkipsTheRestAndRemovesTheWorktree() async throws {
        // Ignores SIGTERM, so the kill after the grace is what ends it.
        let (fx, script) = try await fixture(
            setup: "trap '' TERM\ntouch \"$0.started\"\nsleep 60", check: "touch \"$0.ran\"")
        let doctor = Doctor(project: fx.project, git: fx.git)
        let task = Task { try await doctor.run(base: "main", options: options(grace: 0.5)) }
        #expect(await script.waitFor("setup.sh.started"))
        doctor.stop()
        let report = try await task.value

        #expect(report.wasStopped && !report.passed)
        #expect(report.setup.outcome == .stopped)
        #expect(report.check.outcome == .skipped("interrupted"))
        #expect(!script.exists("check.sh.ran"))
        try await expectClean(fx)
    }

    /// What `workbench run` leaves in the thread folder: this process, or a start time no process has.
    private func writeRunner(_ fx: RunnerFixture, _ id: String, alive: Bool) throws {
        let me = try #require(ProcessTree.member(for: getpid()))
        let info: [String: Any] = [
            "pid": getpid(), "started_seconds": alive ? me.startSeconds : 0, "started_micros": alive ? me.startMicros : 0,
        ]
        try JSONSerialization.data(withJSONObject: info).write(to: fx.project.runnerURL(id))
    }

    @Test func itRefusesWithoutAConfig() async throws {
        let (fx, _) = try await fixture(check: "true")
        try FileManager.default.removeItem(at: fx.project.configURL)
        do {
            _ = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
            Issue.record("expected a refusal")
        } catch let error as DoctorError {
            #expect(error == .noConfig(fx.project.configURL.path))
        }
    }

    @Test func itRunsWithADraftGoalAndLeavesTheThreadAlone() async throws {
        let (fx, _) = try await fixture(check: "true")
        let id = try await fx.service.newThread(name: "work", base: "main")
        let before = try fx.events(id).map(\.seq)
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.passed && report.check.outcome == .passed)
        #expect(try fx.events(id).map(\.seq) == before, "doctor writes nothing to the thread's log")
        #expect(ThreadStore(project: fx.project).activeThreadID() == id)
        try await expectClean(fx)
    }

    @Test func itRunsWithAnApprovedGoalAndNoTurn() async throws {
        let (fx, _) = try await fixture(check: "true")
        let id = try await fx.approvedThread()
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.passed)
        #expect(try fx.kinds(id).last == "goal.approved")
        try await expectClean(fx)
    }

    @Test func itRunsWhenARunnerDiedLeavingATurnOpen() async throws {
        let (fx, _) = try await fixture(check: "true")
        let id = try await fx.approvedThread()
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.turnStarted, turn: 1, data: ["session_id": "s", "resume": false])
        await log.close()
        try writeRunner(fx, id, alive: false)
        #expect(ThreadStore(project: fx.project).state(of: id).openTurn == 1)
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.passed)
        try await expectClean(fx)
    }

    @Test func itRefusesWhileARunnerIsAlive() async throws {
        let (fx, _) = try await fixture(check: "true")
        let id = try await fx.approvedThread()
        try writeRunner(fx, id, alive: true)
        do {
            _ = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
            Issue.record("expected a refusal")
        } catch let error as DoctorError {
            #expect(error == .runnerLive(id))
            #expect("\(error)".contains(id) && "\(error)".contains("running"))
        }
        try await expectClean(fx)
    }

    @Test func anInvalidBaseIsRefusedBeforeGitIsTouched() async throws {
        let (fx, _) = try await fixture(check: "true")
        for bad in ["--upload-pack=x", "a..b", "x y", ""] {
            do {
                _ = try await Doctor(project: fx.project, git: fx.git).run(base: bad, options: options())
                Issue.record("expected a refusal for '\(bad)'")
            } catch let error as DoctorError {
                #expect(error == .invalidBase(bad))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.path))
    }
}

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> (code: Int32?, text: String) {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
        workingDirectory: fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return (code, (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
}

@Suite struct DoctorCommandTests {
    @Test func helpAndInitPointAtDoctor() async throws {
        let fx = try await RunnerFixture()
        let help = try await cli(["help"], in: fx)
        #expect(help.text.contains("doctor [--base <branch>]"))
        #expect(help.text.contains("after goal approve"))
        try FileManager.default.removeItem(at: fx.project.configURL)
        let initialised = try await cli(["init"], in: fx)
        #expect(initialised.code == 0)
        #expect(initialised.text.contains("workbench doctor"))
    }

    @Test func exitCodesFollowTheTable() async throws {
        let (passing, _) = try await fixture(setup: "true", check: "true")
        let ok = try await cli(["doctor"], in: passing)
        #expect(ok.code == 0, "\(ok.text)")
        #expect(ok.text.contains("setup:") && ok.text.contains("passed"))
        #expect(ok.text.contains("check:") && ok.text.contains("claude:") && ok.text.contains("model:"))

        let (undeclared, _) = try await fixture()
        let none = try await cli(["doctor"], in: undeclared)
        #expect(none.code == 0)
        #expect(none.text.contains("turns will end with no check evidence"))

        let (badSetup, _) = try await fixture(setup: "echo auth failed >&2\nexit 4", check: "true")
        let setupFailed = try await cli(["doctor"], in: badSetup)
        #expect(setupFailed.code == 1)
        #expect(setupFailed.text.contains("auth failed") && setupFailed.text.contains("env_pass"))
        #expect(setupFailed.text.contains("skipped"))

        let (failing, _) = try await fixture(check: "echo nope\nexit 1")
        let bad = try await cli(["doctor"], in: failing)
        #expect(bad.code == 1)
        #expect(bad.text.contains("nope") && bad.text.contains("failed (exit 1)"))

        let live = try await failing.service.newThread(name: "work", base: "main")
        let me = try #require(ProcessTree.member(for: getpid()))
        let info: [String: Any] = ["pid": getpid(), "started_seconds": me.startSeconds, "started_micros": me.startMicros]
        try JSONSerialization.data(withJSONObject: info).write(to: failing.project.runnerURL(live))
        let refused = try await cli(["doctor"], in: failing)
        #expect(refused.code == 6, "\(refused.text)")
        #expect(refused.text.contains("refused"))

        let usage = try await cli(["doctor", "--base", "a..b"], in: passing)
        #expect(usage.code == 2)
        #expect(try await cli(["doctor", "stray"], in: passing).code == 2)
    }
}

@Suite struct DoctorOwnershipTests {
    @Test func aSecondDoctorIsRefusedAndTheFirstKeepsItsWorktree() async throws {
        let (fx, script) = try await fixture(setup: "touch \"$0.started\"\nsleep 5", check: "true")
        let first = Doctor(project: fx.project, git: fx.git)
        let task = Task { try await first.run(base: "main", options: options()) }
        #expect(await script.waitFor("setup.sh.started"))

        do {
            _ = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
            Issue.record("expected a refusal")
        } catch let error as DoctorError {
            #expect(error == .alreadyRunning)
        }
        #expect(FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.appendingPathComponent("doctor").path))
        let report = try await task.value
        #expect(report.passed)
        try await expectClean(fx)
    }

    @Test func aWorktreeThatCannotBeRemovedIsReportedNotHidden() async throws {
        // A locked worktree: `worktree remove --force` refuses it.
        let (fx, _) = try await fixture(setup: "git worktree lock \"$PWD\"", check: "true")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.setup.outcome == .passed && report.check.outcome == .passed)
        #expect(!report.passed)
        let problem = try #require(report.cleanupProblem)
        #expect(problem.contains("git worktree remove --force --force"))
    }
}

@Suite struct DoctorBoundaryTests {
    @Test func aThreadCannotBeStartedWhileDoctorRuns() async throws {
        let (fx, script) = try await fixture(setup: "touch \"$0.started\"\nsleep 5", check: "true")
        let task = Task { try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options()) }
        #expect(await script.waitFor("setup.sh.started"))

        do {
            _ = try await fx.service.newThread(name: "work", base: "main")
            Issue.record("expected a refusal")
        } catch let error as ThreadStoreError {
            #expect(error == .doctorRunning)
        }
        #expect(ThreadStore(project: fx.project).threadIDs().isEmpty, "nothing was created")
        _ = try await task.value
        _ = try await fx.service.newThread(name: "work", base: "main")
    }

    @Test func aWorktreeThatFailsDuringCreationIsStillCleanedUp() async throws {
        let (fx, _) = try await fixture(check: "true")
        let hook = fx.repo.appendingPathComponent(".git/hooks/post-checkout")
        try FileManager.default.createDirectory(
            at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        _ = try? await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        try await expectClean(fx)
    }

    @Test func aDeniedCheckIsReportedAsDenied() async throws {
        let (fx, _) = try await fixture(check: "true")
        var config = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        config += "\ndenied = [\"Bash\"]\n"
        try config.write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.checkDenied)
        #expect(report.check.outcome == .passed, "Workbench itself still runs the check")

        let (open, _) = try await fixture(check: "true")
        let fine = try await Doctor(project: open.project, git: open.git).run(base: "main", options: options())
        #expect(!fine.checkDenied)
    }
}

@Suite struct DoctorVerifyTests {
    @Test func aPassingVerifyReportsItsFilesAndTheContract() async throws {
        let script = try CheckScript()
        let (fx, _) = try await fixture(
            verify: """
                set -e
                printf 'png' > "$WORKBENCH_PROOF_DIR/home.png"
                test "$WORKBENCH_THREAD" = doctor && test -n "$WORKBENCH_PORT" && test -f "$WORKBENCH_GOAL"
                test -d "$WORKBENCH_PROOF_DIR" && pwd > "\(script.path("cwd"))"
                """)
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        #expect(report.passed)
        #expect(report.verify.outcome == .passed)
        #expect(report.verify.durationMs != nil)
        #expect(report.verifyFiles.map(\.name) == ["home.png"] && report.verifyFiles.first?.bytes == 3)
        #expect(report.verifyWarning == nil)
        let cwd = try String(contentsOfFile: script.path("cwd"), encoding: .utf8)
        #expect(cwd.contains("worktrees/doctor"), "it ran in the throwaway worktree")
        #expect(!FileManager.default.fileExists(atPath: fx.project.threadsDirectory.appendingPathComponent("doctor").path))
        try await expectClean(fx)
    }

    @Test func aFailingVerifyShowsItsOutput() async throws {
        let (fx, _) = try await fixture(verify: "echo 'no browser'\nexit 4")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        #expect(!report.passed)
        #expect(report.verify.outcome == .failed(how: "failed (exit 4)"))
        #expect(report.verify.tail.contains("no browser"))
        try await expectClean(fx)
    }

    @Test func aVerifyThatHangsTimesOut() async throws {
        let (fx, _) = try await fixture(verify: "sleep 60")
        var o = options(grace: 0.5)
        o.verifyTimeout = 2
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: o)

        #expect(report.verify.outcome == .timedOut && !report.passed, "\(report.verify)")
        try await expectClean(fx)
    }

    @Test func aServerTheVerifyDetachedDoesNotOutliveDoctor() async throws {
        let script = try CheckScript()
        let body = """
            /usr/bin/python3 -c '
            import os
            if os.fork() == 0:
                os.setsid()
                if os.fork() == 0:
                    open("\(script.path("server"))", "w").write(str(os.getpid()))
                    os.execvp("sleep", ["sleep", "300"])
                os._exit(0)
            '
            while [ ! -s "\(script.path("server"))" ]; do sleep 0.1; done
            """
        let (fx, _) = try await fixture(verify: body)
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        #expect(report.verify.outcome == .passed)
        let server = try script.pid("server")
        defer { kill(server, SIGKILL) }
        #expect(await FakeClaude.waitUntilGone(server), "a detached server does not outlive doctor")
        try await expectClean(fx)
    }

    @Test func aVerifyThatWritesNothingPassesWithAWarning() async throws {
        let (fx, _) = try await fixture(verify: "true")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())

        #expect(report.passed && report.verify.outcome == .passed)
        #expect(report.verifyFiles.isEmpty)
        #expect(report.verifyWarning?.contains("WORKBENCH_PROOF_DIR") == true)
    }

    @Test func verifyIsSkippedWhenSetupOrCheckDidNotPass() async throws {
        let (a, scriptA) = try await fixture(setup: "exit 1", verify: "touch \"$0.ran\"")
        let afterSetup = try await Doctor(project: a.project, git: a.git).run(base: "main", options: options())
        #expect(afterSetup.verify.outcome == .skipped("setup did not pass"))
        #expect(!scriptA.exists("verify.sh.ran"))

        let (b, scriptB) = try await fixture(check: "exit 1", verify: "touch \"$0.ran\"")
        let afterCheck = try await Doctor(project: b.project, git: b.git).run(base: "main", options: options())
        #expect(afterCheck.verify.outcome == .skipped("check did not pass") && !afterCheck.passed)
        #expect(!scriptB.exists("verify.sh.ran"))
    }

    @Test func aStopBetweenStepsIsAStopNotAFailure() {
        func step(_ outcome: DoctorStep.Outcome) -> DoctorStep {
            DoctorStep(command: "x", outcome: outcome, tail: "", hint: "")
        }
        let report = DoctorReport(
            base: "main", claudePath: "claude", bashAvailable: true, setup: step(.passed), check: step(.passed),
            verify: step(.skipped("interrupted")))
        #expect(report.wasStopped && !report.passed)
        var other = report
        other.verify = step(.skipped("check did not pass"))
        #expect(!other.wasStopped)
    }

    @Test func noVerifyCommandIsNotAFailure() async throws {
        let (fx, _) = try await fixture(check: "true")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.passed && report.verify.outcome == .notDeclared && report.verify.command == nil)
    }

    @Test func aVerifyAloneIsEnoughToRunDoctor() async throws {
        let (fx, _) = try await fixture(verify: "true")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.verify.outcome == .passed && report.setup.outcome == .notDeclared)
    }

    @Test func aDesktopAppWithoutScreenRecordingFailsBeforeVerifyRuns() async throws {
        let (fx, script) = try await fixture(verify: "touch \"$0.ran\"", extra: "app_type = \"desktop\"")
        var o = options(["TERM_PROGRAM": "iTerm.app"])
        o.screenRecordingGranted = { false }
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: o)

        #expect(!report.passed && report.appType == .desktop)
        guard case .failed(let how) = report.verify.outcome else {
            Issue.record("not failed")
            return
        }
        #expect(how.contains("Screen Recording") && how.contains("iTerm.app"))
        #expect(report.verify.hint.contains("Privacy & Security"))
        #expect(!script.exists("verify.sh.ran"))
        try await expectClean(fx)
    }

    @Test func aDesktopAppWithTheGrantRunsVerify() async throws {
        let (fx, script) = try await fixture(verify: "touch \"$0.ran\"", extra: "app_type = \"desktop\"")
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
        #expect(report.verify.outcome == .passed && script.exists("verify.sh.ran"))
    }

    @Test(arguments: ["app_type = \"web\"", ""])
    func webAndUnsetNeverAskForScreenRecording(extra: String) async throws {
        let (fx, script) = try await fixture(verify: "touch \"$0.ran\"", extra: extra)
        var o = options()
        o.screenRecordingGranted = { false }
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: o)
        #expect(report.passed && script.exists("verify.sh.ran") && report.appType == .web)
    }

    @Test func stoppingDuringVerifyEndsItAndRemovesTheWorktree() async throws {
        let (fx, script) = try await fixture(verify: "trap '' TERM\ntouch \"$0.started\"\nsleep 60")
        let doctor = Doctor(project: fx.project, git: fx.git)
        let task = Task { try await doctor.run(base: "main", options: options(grace: 0.5)) }
        #expect(await script.waitFor("verify.sh.started"))
        doctor.stop()
        let report = try await task.value

        #expect(report.wasStopped && report.verify.outcome == .stopped)
        try await expectClean(fx)
    }
}
