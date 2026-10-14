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
    o.killGrace = grace
    return o
}

private func fixture(setup: String? = nil, check: String? = nil, extra: String = "") async throws -> (
    RunnerFixture, CheckScript
) {
    let script = try CheckScript()
    var lines: [String] = []
    if let setup { lines.append("setup_command = \"\(try script.write(setup, name: "setup.sh"))\"") }
    if let check { lines.append("check_command = \"\(try script.write(check, name: "check.sh"))\"") }
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

    @Test func itRefusesWhileAThreadIsActiveAndWithoutAConfig() async throws {
        let (fx, _) = try await fixture(check: "true")
        let id = try await fx.service.newThread(name: "work", base: "main")
        do {
            _ = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
            Issue.record("expected a refusal")
        } catch let error as DoctorError {
            #expect(error == .threadActive(id))
        }
        try await expectClean(fx)

        try FileManager.default.removeItem(at: fx.project.configURL)
        do {
            _ = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options())
            Issue.record("expected a refusal")
        } catch let error as DoctorError {
            #expect(error == .noConfig(fx.project.configURL.path))
        }
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

        let (failing, _) = try await fixture(check: "echo nope\nexit 1")
        let bad = try await cli(["doctor"], in: failing)
        #expect(bad.code == 1)
        #expect(bad.text.contains("nope") && bad.text.contains("failed (exit 1)"))

        _ = try await failing.service.newThread(name: "work", base: "main")
        let refused = try await cli(["doctor"], in: failing)
        #expect(refused.code == 6, "\(refused.text)")
        #expect(refused.text.contains("refused"))

        let usage = try await cli(["doctor", "--base", "a..b"], in: passing)
        #expect(usage.code == 2)
        #expect(try await cli(["doctor", "stray"], in: passing).code == 2)
    }
}
