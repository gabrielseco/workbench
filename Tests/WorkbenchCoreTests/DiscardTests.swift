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
        #expect(try await cli(["status", id], in: fx).text.contains("ended: discarded"))
        #expect(try await cli(["review", id], in: fx).text.contains("this thread was discarded"))
        _ = try await fx.service.newThread(name: "next", base: "main")
    }

    @Test func withoutYesAndWithoutATerminalNothingIsRemoved() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        let before = try Data(contentsOf: fx.project.eventsURL(id))

        let result = try await cli(["discard"], in: fx)
        #expect(result.exit?.termination == .exited(1), "\(result.text)")
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
        #expect(Confirmation.ask(yes: false, interactive: true, readLine: { " YES " }) == .proceed)
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
    }

    @Test func aFailurePartwayLeavesTheThreadActiveAndASecondDiscardFinishes() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        // A stale ref lock makes `git branch -D` fail after the worktree is already gone.
        let lock = fx.repo.appendingPathComponent(".git/refs/heads/workbench/\(id).lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) { try await fx.service.discard(id: id) }
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
}
