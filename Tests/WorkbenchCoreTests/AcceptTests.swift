import Foundation
import Testing

@testable import WorkbenchCore

private struct CLIResult {
    var lines: [String]
    var exit: ProcessExit?
    var text: String { lines.joined(separator: "\n") }
}

/// A HOME whose git config names an author, so a commit made by the CLI works on a machine with none.
private func gitHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("wb-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try "[user]\n\tname = t\n\temail = t@example.com\n".write(
        to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
    return home
}

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> CLIResult {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": try gitHome().path, "USER": NSUserName()],
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

private func write(_ name: String, _ text: String, in worktree: URL) throws {
    try text.write(to: worktree.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

private func gitOut(_ args: [String], _ dir: URL, _ fx: RunnerFixture) async throws -> String {
    try await fx.git.run(args, in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A thread that has run once and then has a modified, a staged and an untracked file in its worktree.
private func dirtyThread(_ fx: RunnerFixture) async throws -> (id: String, worktree: URL) {
    let id = try await fx.approvedThread()
    _ = try await fx.runner(id).run(fx.options())
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    _ = try await fx.git.run(["reset", "-q", "--hard"], in: worktree)
    _ = try await fx.git.run(["clean", "-qfd"], in: worktree)
    try write("a.txt", "one\nhello\n", in: worktree)
    try write("staged.txt", "staged\n", in: worktree)
    _ = try await fx.git.run(["add", "staged.txt"], in: worktree)
    try write("loose.txt", "loose\n", in: worktree)
    return (id, worktree)
}

@Suite struct AcceptTests {
    @Test func acceptCommitsEverythingRecordsTheDecisionAndFreesTheSlot() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await dirtyThread(fx)
        let before = try await gitOut(["rev-parse", "main"], fx.repo, fx)

        let result = try await cli(["accept"], in: fx)
        #expect(result.exit?.termination == .exited(0), "\(result.text)")
        #expect(result.text.contains("loose.txt") && result.text.contains("staged.txt"), "\(result.text)")
        #expect(result.text.contains("Nothing was pushed"))

        #expect(try await gitOut(["status", "--porcelain"], worktree, fx).isEmpty, "the worktree is clean")
        let branch = "workbench/\(id)"
        #expect(try await gitOut(["rev-list", "--count", "main..\(branch)"], fx.repo, fx) == "1")
        let files = try await gitOut(["show", "--name-only", "--format=", branch], fx.repo, fx)
        #expect(Set(files.split(separator: "\n").map(String.init)) == ["a.txt", "staged.txt", "loose.txt"])
        #expect(try await gitOut(["rev-parse", "main"], fx.repo, fx) == before, "main is untouched")

        let message = try await gitOut(["log", "-1", "--format=%B", branch], fx.repo, fx)
        #expect(message.hasPrefix("chore: work"), "\(message)")
        #expect(message.contains("Add a greeting to a.txt."))
        #expect(message.contains("Workbench-Thread: \(id)"))

        let events = try fx.events(id)
        #expect(events.last?.kind == .reviewDecision)
        #expect(events.last?.data["decision"]?.stringValue == "accepted")
        #expect(events.last?.data["by"]?.stringValue == "user")
        #expect(try fx.contents(id).isHealthy)
        #expect(FileManager.default.fileExists(atPath: worktree.path), "the worktree is kept for ship")

        for command in ["log", "status", "review"] {
            let shown = try await cli([command, id], in: fx)
            #expect(shown.exit?.termination == .exited(0), "\(command): \(shown.text)")
        }
        #expect(try await cli(["status", id], in: fx).text.contains("ended: accepted"))
        let next = try await cli(["goal", "new", "next"], in: fx)
        #expect(next.exit?.termination == .exited(0), "the slot is free: \(next.text)")
    }

    @Test func aGivenMessageIsUsedVerbatimAndNeverReachesAShell() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await dirtyThread(fx)
        let marker = fx.repo.appendingPathComponent("pwned")
        let message = "fix: it's \"quoted\" $(touch \(marker.path)) `touch \(marker.path)`\n\nbody; rm -rf /\n- dash"

        let result = try await cli(["accept", "-m", message], in: fx)
        #expect(result.exit?.termination == .exited(0), "\(result.text)")
        let stored = try await gitOut(["log", "-1", "--format=%B", "workbench/\(id)"], fx.repo, fx)
        #expect(stored == message)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func anEmptyMessageChangesNothing() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await dirtyThread(fx)
        for text in ["", "  \n "] {
            await #expect(throws: ThreadServiceError.emptyMessage) { try await fx.service.accept(id: id, message: text) }
        }
        let cliResult = try await cli(["accept", "-m", ""], in: fx)
        #expect(cliResult.exit?.termination == .exited(1), "\(cliResult.text)")
        #expect(try await gitOut(["status", "--porcelain"], worktree, fx).contains("loose.txt"))
        #expect(try await gitOut(["rev-list", "--count", "main..workbench/\(id)"], fx.repo, fx) == "0")
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)
    }

    @Test func ignoredFilesAreNotCommittedAndThereIsNothingToPushTo() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await dirtyThread(fx)
        try write(".gitignore", "secret.log\n", in: worktree)
        try write("secret.log", "token\n", in: worktree)

        try await fx.service.accept(id: id, message: "chore: keep it")
        let tracked = try await gitOut(["ls-tree", "-r", "--name-only", "workbench/\(id)"], fx.repo, fx)
        #expect(!tracked.contains("secret.log"))
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("secret.log").path))
        #expect(try await gitOut(["remote"], fx.repo, fx).isEmpty)
    }

    @Test func aLiveRunnerAnEndedThreadAndAnEmptyBranchAreRefusedAndNothingChanges() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await dirtyThread(fx)

        let me = getpid()
        let started = try #require(ProcessTree.member(for: me))
        let info: [String: Any] = [
            "pid": me, "started_seconds": started.startSeconds, "started_micros": started.startMicros,
        ]
        try JSONSerialization.data(withJSONObject: info).write(to: fx.project.runnerURL(id))
        await #expect(throws: ThreadServiceError.running(pid: me)) { try await fx.service.accept(id: id) }
        #expect(try await gitOut(["status", "--porcelain"], worktree, fx).contains("loose.txt"))
        try FileManager.default.removeItem(at: fx.project.runnerURL(id))

        _ = try await fx.git.run(["add", "-A"], in: worktree)
        _ = try await fx.git.run(["reset", "-q", "--hard"], in: worktree)
        _ = try await fx.git.run(["clean", "-qfd"], in: worktree)
        await #expect(throws: ThreadServiceError.nothingToAccept) { try await fx.service.accept(id: id) }
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)

        try write("late.txt", "x\n", in: worktree)
        try await fx.service.accept(id: id, message: "chore: late")
        await #expect(throws: ThreadServiceError.threadEnded("accepted")) { try await fx.service.accept(id: id) }
    }

    @Test func workAlreadyCommittedByTheModelIsAcceptedAsItIs() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await dirtyThread(fx)
        _ = try await fx.git.run(["add", "-A"], in: worktree)
        _ = try await fx.git.run(["commit", "-q", "-m", "model work"], in: worktree)

        let result = try await fx.service.accept(id: id)
        #expect(!result.committedNow)
        #expect(try await gitOut(["rev-list", "--count", "main..workbench/\(id)"], fx.repo, fx) == "1")
        #expect(try fx.events(id).last?.data["decision"]?.stringValue == "accepted")
    }

    @Test func anOpenTurnLeftByADeadRunnerIsRecordedAsInterruptedFirst() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await dirtyThread(fx)
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.turnStarted, turn: 2, data: ["session_id": "s", "resume": true])
        _ = try await log.append(.checkStarted, turn: 2, data: ["command": "c"])
        await log.close()

        try await fx.service.accept(id: id, message: "chore: recovered")
        let events = try fx.events(id)
        #expect(try fx.contents(id).isHealthy)
        #expect(events.last?.data["decision"]?.stringValue == "accepted")
        #expect(events.contains { $0.kind == .turnEnded && $0.data["result"]?.stringValue == "interrupted" })
        #expect(events.contains { $0.kind == .checkRan && $0.data["result"]?.stringValue == "interrupted" })
    }

    @Test func aFailedCheckNeedsYesWhenThereIsNoTerminal() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(try script.write("echo broken\nexit 3"))
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.check?.result == .failed)
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try write("loose.txt", "x\n", in: worktree)

        let refused = try await cli(["accept"], in: fx)
        #expect(refused.exit?.termination == .exited(1), "\(refused.text)")
        #expect(refused.text.contains("did not pass"), "\(refused.text)")
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)
        #expect(try await gitOut(["status", "--porcelain"], worktree, fx).contains("loose.txt"))

        let accepted = try await cli(["accept", "--yes"], in: fx)
        #expect(accepted.exit?.termination == .exited(0), "\(accepted.text)")
        #expect(try fx.events(id).last?.data["decision"]?.stringValue == "accepted")
    }

    @Test func aRejectedCommitLeavesTheThreadActiveAndASecondAcceptFinishes() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await dirtyThread(fx)
        let hook = fx.repo.appendingPathComponent(".git/hooks/pre-commit")
        try FileManager.default.createDirectory(
            at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho no commits today >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        do {
            try await fx.service.accept(id: id, message: "chore: try")
            Issue.record("expected the commit to be rejected")
        } catch let error as ThreadServiceError {
            #expect(error.description.contains("run `workbench accept` again"), "\(error)")
            #expect(error.description.contains("no commits today"), "\(error)")
        }
        #expect(try fx.events(id).last?.kind != .reviewDecision)
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)
        #expect(try await gitOut(["status", "--porcelain"], worktree, fx).contains("loose.txt"))

        try FileManager.default.removeItem(at: hook)
        try await fx.service.accept(id: id, message: "chore: try")
        #expect(try await gitOut(["status", "--porcelain"], worktree, fx).isEmpty)
        #expect(try fx.events(id).last?.data["decision"]?.stringValue == "accepted")
    }

    @Test func aWorktreeOnAnotherBranchIsNeverCommitted() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await dirtyThread(fx)
        _ = try await fx.git.run(["checkout", "-q", "-b", "elsewhere"], in: worktree)
        let tip = try await gitOut(["rev-parse", "elsewhere"], fx.repo, fx)

        await #expect(throws: ThreadServiceError.self) { try await fx.service.accept(id: id, message: "chore: x") }
        #expect(try await gitOut(["rev-parse", "elsewhere"], fx.repo, fx) == tip)
        #expect(try await gitOut(["status", "--porcelain"], worktree, fx).contains("loose.txt"))
        #expect(ThreadStore(project: fx.project).state(of: id).isActive)
    }

    @Test func theBranchComesFromTheIdNotFromTheLog() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await dirtyThread(fx)
        _ = try await fx.git.run(["branch", "precious"], in: fx.repo)
        let url = fx.project.eventsURL(id)
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "\"branch\":\"workbench/\(id)\"", with: "\"branch\":\"precious\"")
            .write(to: url, atomically: true, encoding: .utf8)
        let tip = try await gitOut(["rev-parse", "precious"], fx.repo, fx)

        try await fx.service.accept(id: id, message: "chore: ok")
        #expect(try await gitOut(["rev-parse", "precious"], fx.repo, fx) == tip)
        #expect(try await gitOut(["rev-list", "--count", "main..workbench/\(id)"], fx.repo, fx) == "1")
    }
}
