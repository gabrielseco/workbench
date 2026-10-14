import Foundation
import Testing

@testable import WorkbenchCore

private struct CLIResult {
    var lines: [String]
    var exit: ProcessExit?
    var text: String { lines.joined(separator: "\n") }
}

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> CLIResult {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
        workingDirectory: fx.repo, timeout: 60)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var result = CLIResult(lines: [], exit: nil)
    for await event in run.events {
        if case .line(let line) = event { result.lines.append(line) }
        if case .exited(let e) = event { result.exit = e }
    }
    return result
}

private func branchExists(_ id: String, _ fx: RunnerFixture) async throws -> Bool {
    try await fx.git.run(["rev-parse", "--verify", "--quiet", "refs/heads/workbench/\(id)"], in: fx.repo)
        .succeeded
}

/// A thread that has run once, with a committed file and a loose one in its worktree.
private func workedThread(_ fx: RunnerFixture) async throws -> (id: String, worktree: URL) {
    let id = try await fx.approvedThread()
    _ = try await fx.runner(id).run(fx.options())
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    try "kept in a commit\n".write(
        to: worktree.appendingPathComponent("committed.txt"), atomically: true, encoding: .utf8)
    _ = try await fx.git.run(["add", "committed.txt"], in: worktree)
    _ = try await fx.git.run(["commit", "-q", "-m", "model work"], in: worktree)
    try "loose\n".write(to: worktree.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)
    return (id, worktree)
}

@Suite struct DiscardTests {
    @Test func discardRemovesWorktreeAndBranchKeepsTheLogAndFreesTheSlot() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)

        let result = try await cli(["discard", "--yes"], in: fx)
        #expect(result.exit?.termination == .exited(0), "\(result.text)")
        #expect(result.text.contains("loose.txt"), "what is lost is listed: \(result.text)")
        #expect(result.text.contains("model work"), "commits are listed: \(result.text)")

        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try await !branchExists(id, fx))
        let events = try fx.events(id)
        #expect(events.last?.kind == .reviewDecision)
        #expect(events.last?.data["decision"]?.stringValue == "discarded")
        #expect(try fx.contents(id).isHealthy)

        for command in ["log", "status", "review"] {
            let shown = try await cli([command, id], in: fx)
            #expect(shown.exit?.termination == .exited(0), "\(command): \(shown.text)")
        }
        #expect(events.last?.data["by"]?.stringValue == "user")
        #expect(try await cli(["status", id], in: fx).text.contains("ended: discarded"))
        #expect(try await cli(["log", id], in: fx).text.contains("decision: discarded"))
        #expect(try await cli(["review", id], in: fx).text.contains("this thread was discarded"))
        let next = try await cli(["goal", "new", "next"], in: fx)
        #expect(next.exit?.termination == .exited(0), "the slot is free: \(next.text)")
    }

    @Test func withoutYesAndWithoutATerminalNothingIsRemoved() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        let before = try Data(contentsOf: fx.project.eventsURL(id))

        let result = try await cli(["discard"], in: fx)
        #expect(result.exit?.termination == .exited(6), "\(result.text)")
        #expect(result.text.contains("will delete"), "the plan is shown before refusing")
        #expect(!result.text.contains("discarded \(id)"))
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(try await branchExists(id, fx))
        #expect(try Data(contentsOf: fx.project.eventsURL(id)) == before)
    }

    @Test func theAnswerDecides() {
        #expect(Confirmation.ask(yes: true, interactive: false, readLine: { nil }) == .proceed)
        #expect(Confirmation.ask(yes: false, interactive: false, readLine: { "y" }) == .refused)
        #expect(Confirmation.ask(yes: false, interactive: true, readLine: { "y" }) == .proceed)
        #expect(Confirmation.ask(yes: false, interactive: true, readLine: { " Y " }) == .proceed)
        #expect(Confirmation.ask(yes: false, interactive: true, readLine: { "yes" }) == .declined)
        #expect(Confirmation.ask(yes: false, interactive: true, readLine: { "n" }) == .declined)
        #expect(Confirmation.ask(yes: false, interactive: true, readLine: { "" }) == .declined)
        #expect(Confirmation.ask(yes: false, interactive: true, readLine: { "yep" }) == .declined)
        #expect(Confirmation.ask(yes: false, interactive: true, readLine: { nil }) == .declined)
    }

    @Test func aLiveRunnerAndAnEndedThreadAreRefusedAndNothingIsRemoved() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)

        // This test process stands in for the runner: same pid and start time as runner.json records.
        let me = getpid()
        let started = try #require(ProcessTree.member(for: me))
        let info: [String: Any] = [
            "pid": me, "started_seconds": started.startSeconds, "started_micros": started.startMicros,
        ]
        try JSONSerialization.data(withJSONObject: info).write(to: fx.project.runnerURL(id))
        await #expect(throws: ThreadServiceError.running(pid: me)) { try await fx.service.discard(id: id) }
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(try await branchExists(id, fx))
        try FileManager.default.removeItem(at: fx.project.runnerURL(id))

        try await fx.service.discard(id: id)
        await #expect(throws: ThreadServiceError.threadEnded("discarded")) { try await fx.service.discard(id: id) }
    }

    @Test func anOpenTurnLeftByADeadRunnerIsRecordedAsInterruptedFirst() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await workedThread(fx)
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.turnStarted, turn: 2, data: ["session_id": "s", "resume": true])
        _ = try await log.append(.checkStarted, turn: 2, data: ["command": "c"])
        await log.close()

        try await fx.service.discard(id: id)
        let events = try fx.events(id)
        #expect(try fx.contents(id).isHealthy)
        let kinds = events.suffix(3).map(\.kind)
        #expect(kinds == [.checkRan, .turnEnded, .reviewDecision] || kinds == [.turnEnded, .checkRan, .reviewDecision],
            "\(kinds)")
        #expect(events.contains { $0.kind == .turnEnded && $0.data["result"]?.stringValue == "interrupted" })
        #expect(events.contains { $0.kind == .checkRan && $0.data["result"]?.stringValue == "interrupted" })
    }

    @Test func aFailurePartwayLeavesTheThreadActiveAndASecondDiscardFinishes() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        // A stale ref lock makes `git branch -D` fail after the worktree is already gone.
        let lock = fx.repo.appendingPathComponent(".git/refs/heads/workbench/\(id).lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)

        do {
            try await fx.service.discard(id: id)
            Issue.record("expected the branch deletion to fail")
        } catch let error as ThreadServiceError {
            let message = error.description
            #expect(message.contains("worktree is removed"), "\(message)")
            #expect(message.contains("workbench/\(id)"), "\(message)")
            #expect(message.contains("run `workbench discard` again"), "\(message)")
        }
        #expect(!FileManager.default.fileExists(atPath: worktree.path), "the worktree is already gone")
        #expect(try await branchExists(id, fx))
        #expect(try fx.events(id).last?.kind != .reviewDecision)
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)

        try FileManager.default.removeItem(at: lock)
        try await fx.service.discard(id: id)
        #expect(try await !branchExists(id, fx))
        #expect(try fx.events(id).last?.data["decision"]?.stringValue == "discarded")
    }

    @Test func onlyTheThreadsOwnBranchIsEverDeleted() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await workedThread(fx)
        _ = try await fx.git.run(["branch", "precious"], in: fx.repo)

        // A log that names another branch, as if hand-edited: the name must come from the id, not the log.
        let url = fx.project.eventsURL(id)
        let text = try String(contentsOf: url, encoding: .utf8)
        var rewritten = text.replacingOccurrences(of: "\"branch\":\"workbench/\(id)\"", with: "\"branch\":\"precious\"")
        rewritten = rewritten.replacingOccurrences(of: "\"branch\":\"main\"", with: "\"branch\":\"precious\"")
        try rewritten.write(to: url, atomically: true, encoding: .utf8)

        try await fx.service.discard(id: id)
        #expect(try await fx.git.run(["rev-parse", "--verify", "--quiet", "refs/heads/precious"], in: fx.repo).succeeded)
        #expect(try await fx.git.run(["rev-parse", "--verify", "--quiet", "refs/heads/main"], in: fx.repo).succeeded)
        #expect(try await !branchExists(id, fx))
    }

    @Test func aThreadWithNothingToDiscardPointsToAbandon() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        await #expect(throws: ThreadServiceError.nothingToDiscard) { try await fx.service.discard(id: id) }
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)
    }

    @Test func childrenTheRunnerLeftInTheWorktreeAreSweptBeforeItIsRemoved() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)

        let null = open("/dev/null", O_WRONLY)
        defer { close(null) }
        let sh = try Spawner.spawn(
            executable: "/bin/sh", arguments: ["-c", "exec sleep 300 &"], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: worktree.path, stdout: null, stderr: null)
        var status: Int32 = 0
        waitpid(sh, &status, 0)
        var orphan: ProcessMember?
        let deadline = Date().addingTimeInterval(5)
        while orphan == nil, Date() < deadline {
            orphan = OrphanSweeper.orphans(inside: worktree).first
            if orphan == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let member = try #require(orphan, "the helper should be orphaned and found by its cwd")
        defer { kill(member.pid, SIGKILL) }

        try await fx.service.discard(id: id)
        #expect(await FakeClaude.waitUntilGone(member.pid))
        #expect(try fx.kinds(id).contains("orphans.swept"))
    }

    @Test func aCutFileListCannotBeConfirmedInteractively() {
        var summary = DiffSummary(base: "b", files: [], truncated: true, totalFiles: 600)
        let cut = DiscardPlan(id: "t", worktree: URL(fileURLWithPath: "/w"), branch: "workbench/t",
            diff: .summary(summary), commits: [])
        #expect(!cut.fullyShown)
        summary.truncated = false
        #expect(DiscardPlan(id: "t", worktree: URL(fileURLWithPath: "/w"), branch: nil,
            diff: .summary(summary), commits: []).fullyShown)
        #expect(!DiscardPlan(id: "t", worktree: URL(fileURLWithPath: "/w"), branch: nil,
            diff: .unavailable(reason: "git failed"), commits: []).fullyShown)
    }

    @Test func newWorkAfterThePlanWasShownIsNotDeletedByTheOldAnswer() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        let shown = try await fx.service.discardPlan(id: id)
        try "written after the list was shown\n".write(
            to: worktree.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)

        await #expect(throws: ThreadServiceError.changedSinceShown) {
            try await fx.service.discard(id: id, shown: shown)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("late.txt").path))
        #expect(try await branchExists(id, fx))
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)

        let again = try await fx.service.discardPlan(id: id)
        try await fx.service.discard(id: id, shown: again)
    }

    @Test func commitsThatCouldNotBeListedAreNotFullyShown() {
        let plan = DiscardPlan(
            id: "t", worktree: nil, branch: "workbench/t", diff: .unavailable(reason: "gone"), commits: [],
            commitsKnown: false)
        #expect(!plan.fullyShown)
        #expect(plan.render().contains { $0.contains("could not be listed") })
    }

    @Test func failedGitLogDoesNotMeanThereAreNoCommits() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await workedThread(fx)
        let wrapper = fx.repo.appendingPathComponent("failing-git")
        let script = """
            #!/bin/sh
            if [ "$1" = log ]; then exit 1; fi
            exec "\(fx.git.executable.path)" "$@"
            """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let git = GitRunner(executable: wrapper, environment: fx.git.environment)
        let service = ThreadService(project: fx.project, git: git)
        let plan = try await service.discardPlan(id: id)
        #expect(!plan.commitsKnown)
        #expect(!plan.fullyShown)
        if case .summary = plan.diff {} else { Issue.record("only commit inspection should fail") }
        #expect(try await branchExists(id, fx))
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)
    }

    @Test func ignoredFilesAreShownAndNewIgnoredFilesInvalidateConfirmation() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try "*.private\n".write(to: worktree.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let ignored = worktree.appendingPathComponent("notes.private")
        try "notes\n".write(to: ignored, atomically: true, encoding: .utf8)
        let shown = try await fx.service.discardPlan(id: id)
        #expect(shown.render().contains { $0.contains("notes.private") })
        try "more notes\n".write(
            to: worktree.appendingPathComponent("late.private"), atomically: true, encoding: .utf8)
        await #expect(throws: ThreadServiceError.changedSinceShown) {
            try await fx.service.discard(id: id, shown: shown)
        }
        #expect(FileManager.default.fileExists(atPath: ignored.path))
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)
    }

    @Test func moreThanTenCommitsRequireExplicitYes() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        for index in 1...11 {
            let result = try await fx.git.run(["commit", "--allow-empty", "-q", "-m", "extra \(index)"], in: worktree)
            #expect(result.succeeded)
        }
        let plan = try await fx.service.discardPlan(id: id)
        #expect(plan.commits.count == 11)
        #expect(!plan.fullyShown)
        #expect(plan.render().contains { $0.contains("more commits not listed") })
        let refused = try await cli(["discard", id], in: fx)
        #expect(refused.exit?.termination == .exited(6))
        #expect(try await branchExists(id, fx))
        let confirmed = try await cli(["discard", id, "--yes"], in: fx)
        #expect(confirmed.exit?.termination == .exited(0))
    }

    @Test func stagedWorkHiddenByTheWorkingCopyIsListedAndRevalidated() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        let file = worktree.appendingPathComponent("a.txt")
        try "staged work\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await fx.git.run(["add", "a.txt"], in: worktree).succeeded)
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let shown = try await fx.service.discardPlan(id: id)
        #expect(shown.render().contains { $0.contains("a.txt") && $0.contains("(staged)") })
        try "different staged work\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await fx.git.run(["add", "a.txt"], in: worktree).succeeded)
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: ThreadServiceError.changedSinceShown) {
            try await fx.service.discard(id: id, shown: shown)
        }
        #expect(try await branchExists(id, fx))
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)
        let staged = try await fx.git.run(["show", ":a.txt"], in: worktree)
        #expect(staged.stdout == "different staged work\n")
    }

    @Test func sameSizeAndSameCountEditsInvalidateConfirmation() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        let loose = worktree.appendingPathComponent("loose.txt")
        let shown = try await fx.service.discardPlan(id: id)
        try "newer\n".write(to: loose, atomically: false, encoding: .utf8)
        await #expect(throws: ThreadServiceError.changedSinceShown) {
            try await fx.service.discard(id: id, shown: shown)
        }
        #expect(try String(contentsOf: loose, encoding: .utf8) == "newer\n")

        let binary = worktree.appendingPathComponent("b.bin")
        try Data([0, 1, 2]).write(to: binary)
        let binaryShown = try await fx.service.discardPlan(id: id)
        try Data([0, 3, 4]).write(to: binary)
        await #expect(throws: ThreadServiceError.changedSinceShown) {
            try await fx.service.discard(id: id, shown: binaryShown)
        }
        #expect(try Data(contentsOf: binary) == Data([0, 3, 4]))
        #expect(try await branchExists(id, fx))
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)
    }
}
