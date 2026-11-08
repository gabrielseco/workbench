import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct MaxConcurrentChecksConfigTests {
    private let tools = "\n[tools]\navailable = [\"Read\"]\n"

    @Test func twoIsTheDefault() throws {
        #expect(try Config.parse(tools).maxConcurrentChecks == 2)
    }

    @Test func aWholeNumberUpToTheLimitIsKept() throws {
        #expect(try Config.parse("max_concurrent_checks = 1\n" + tools).maxConcurrentChecks == 1)
        let limit = Config.maxActiveThreadsLimit
        #expect(try Config.parse("max_concurrent_checks = \(limit)\n" + tools).maxConcurrentChecks == limit)
    }

    @Test func anythingElseIsAConfigError() {
        for bad in ["0", "-1", "\(Config.maxActiveThreadsLimit + 1)", "\"2\"", "1.5"] {
            #expect(throws: ConfigError.self) { _ = try Config.parse("max_concurrent_checks = \(bad)\n" + tools) }
        }
    }
}

@Suite struct GitSharedRepositoryTests {
    @Test func onlyACommandThatChangesTheSharedRepositoryIsSerialized() {
        let changing = [
            ["fetch", "--quiet", "origin", "main"], ["gc"], ["push", "origin", "x"], ["update-ref", "-d", "refs/heads/x"],
            ["worktree", "add", "p", "HEAD"], ["worktree", "remove", "--force", "p"], ["worktree", "prune"],
            ["branch", "-D", "x"], ["-C", "/r", "-c", "a=b", "fetch"], ["branch", "--delete", "x"],
        ]
        for arguments in changing { #expect(GitSharedRepository.changesIt(arguments), "\(arguments)") }
        let reading = [
            ["status"], ["rev-parse", "HEAD"], ["worktree", "list", "--porcelain"], ["branch", "--list"], ["diff"], ["log"],
            ["show-ref", "--verify", "x"], ["remote", "get-url", "origin"], [],
        ]
        for arguments in reading { #expect(!GitSharedRepository.changesIt(arguments), "\(arguments)") }
    }

    @Test func aLockFileErrorIsRecognizedByGitsOwnWords() {
        #expect(GitSharedRepository.isLockFileError("fatal: Unable to create '/r/.git/index.lock': File exists."))
        #expect(GitSharedRepository.isLockFileError("error: cannot lock ref 'refs/heads/x': Unable to create"))
        #expect(!GitSharedRepository.isLockFileError("fatal: not a git repository"))
        #expect(!GitSharedRepository.isLockFileError("error: File exists"))
    }
}

@Suite(.processGate) struct GitSharedRepositoryRunTests {
    private func lockFile(_ fx: RunnerFixture, _ branch: String) -> URL {
        fx.repo.appendingPathComponent(".git/refs/heads/\(branch).lock")
    }

    @Test func theCommonDirectoryIsTheSameFromTheRepositoryAndFromAWorktree() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        let fromRepo = try #require(GitSharedRepository.commonDirectory(from: fx.repo))
        let fromWorktree = try #require(GitSharedRepository.commonDirectory(from: worktree))
        #expect(fromRepo.resolvingSymlinksInPath() == fromWorktree.resolvingSymlinksInPath())
        #expect(fromRepo.lastPathComponent == ".git")
        #expect(GitSharedRepository.commonDirectory(from: FileManager.default.temporaryDirectory) == nil)
    }

    @Test func aCommandWaitsWhileAnotherHoldsTheProjectsGitLock() async throws {
        let fx = try await RunnerFixture()
        let common = try #require(GitSharedRepository.commonDirectory(from: fx.repo))
        let held = try await GitSharedRepository.acquire(common, arguments: ["test"], wait: 5)
        let finished = Flag()
        let task = Task {
            _ = try await fx.git.run(["worktree", "prune"], in: fx.repo)
            finished.set()
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!finished.isSet, "the prune waits for the lock")
        close(held)
        try await task.value
        #expect(finished.isSet)
    }

    @Test func aReadingCommandDoesNotWaitForTheLock() async throws {
        let fx = try await RunnerFixture()
        let common = try #require(GitSharedRepository.commonDirectory(from: fx.repo))
        let held = try await GitSharedRepository.acquire(common, arguments: ["test"], wait: 5)
        defer { close(held) }
        let status = try await fx.git.run(["status", "--porcelain"], in: fx.repo)
        #expect(status.succeeded)
    }

    @Test func aLockFileThatGoesAwayIsRetriedOnce() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.git.run(["branch", "doomed"], in: fx.repo)
        let lock = lockFile(fx, "doomed")
        try Data().write(to: lock)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            try? FileManager.default.removeItem(at: lock)
        }
        let result = try await fx.git.run(["branch", "-D", "doomed"], in: fx.repo)
        #expect(result.succeeded, "\(result.stderr)")
    }

    @Test func aLockFileThatStaysIsReportedWithGitsOwnMessage() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.git.run(["branch", "doomed"], in: fx.repo)
        let lock = lockFile(fx, "doomed")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }
        let result = try await fx.git.run(["branch", "-D", "doomed"], in: fx.repo)
        #expect(!result.succeeded, "never swallowed")
        #expect(GitSharedRepository.isLockFileError(result.stderr), "\(result.stderr)")
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@Suite(.processGate) struct CheckSlotTests {
    /// A thread of another run in its check: a live runner (this process) and a log with a check that has started.
    private func inCheck(_ fx: RunnerFixture, _ id: String) async throws {
        try FileManager.default.createDirectory(at: fx.project.threadDirectory(id), withIntermediateDirectories: true)
        let member = ProcessTree.member(for: getpid())
        let info: [String: Any] = [
            "pid": getpid(), "started_seconds": member?.startSeconds ?? 0, "started_micros": member?.startMicros ?? 0,
        ]
        try JSONSerialization.data(withJSONObject: info).write(to: fx.project.runnerURL(id))
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.checkStarted, turn: 1, data: ["command": "scripts/check.sh"])
        await log.close()
    }

    @Test func aSlotIsGrantedWhileFewerThanTheCapAreInTheirCheck() async throws {
        let fx = try await RunnerFixture()
        try await inCheck(fx, "other-a")
        let slot = CheckSlot(project: fx.project, threadID: "mine", max: 2)
        let claim = try slot.claim()
        #expect(claim.outcome == .granted)
        claim.release()
        #expect(ThreadStore(project: fx.project).runningChecks(excluding: "mine") == ["other-a"])
    }

    @Test func overTheCapIsRefusedNamingTheRunningOnes() async throws {
        let fx = try await RunnerFixture()
        try await inCheck(fx, "other-a")
        try await inCheck(fx, "other-b")
        let claim = try CheckSlot(project: fx.project, threadID: "mine", max: 2).claim()
        defer { claim.release() }
        guard case .refused(let why) = claim.outcome else {
            Issue.record("expected a refusal")
            return
        }
        #expect(why.contains("other-a") && why.contains("other-b") && why.contains("max_concurrent_checks"))
    }

    @Test func aCheckThatNoRunnerHoldsDoesNotCount() async throws {
        let fx = try await RunnerFixture()
        try await inCheck(fx, "crashed")
        try? FileManager.default.removeItem(at: fx.project.runnerURL("crashed"))
        let running = ThreadStore(project: fx.project).runningChecks()
        #expect(running.isEmpty, "an open check with no live runner is a crash, not a check")
    }

    @Test func aThreadDoesNotCountItself() async throws {
        let fx = try await RunnerFixture()
        try await inCheck(fx, "mine")
        let claim = try CheckSlot(project: fx.project, threadID: "mine", max: 1).claim()
        defer { claim.release() }
        #expect(claim.outcome == .granted)
    }

    @Test func aRunWithTheSlotsFullIsRefusedBeforeAnyTurn() async throws {
        let fx = try await RunnerFixture(extraConfig: "max_concurrent_checks = 1\ncheck_command = \"scripts/check.sh\"")
        let id = try await fx.approvedThread()
        try await inCheck(fx, "other-a")
        do {
            _ = try await fx.runner(id).run(fx.options())
            Issue.record("expected the run to be refused")
        } catch let error as RunnerError {
            #expect(error == .tooManyChecks(running: ["other-a"], max: 1))
        }
        #expect(try fx.kinds(id).filter { $0 == "turn.started" }.isEmpty, "no turn was spent")
        #expect(fx.contentsOfRunnerFile(id) == nil)
    }

    @Test func aCheckRefusedAtTheGateIsRecordedAsFailedWithTheReasonAndRunsNothing() async throws {
        let fx = try await RunnerFixture()
        try await inCheck(fx, "other-a")
        try await inCheck(fx, "other-b")
        let marker = fx.repo.appendingPathComponent("check-ran")
        let script = try CheckScript().write("touch \"\(marker.path)\"", name: "check.sh")
        let log = try EventLogWriter.open(at: fx.project.eventsURL("mine"))
        let runner = CheckRunner(
            command: script, worktree: fx.repo, environment: ["PATH": "/usr/bin:/bin"], timeout: 10, killGrace: 1)
        let report = try await runner.run(
            turn: 1, outputURL: fx.project.checkOutputURL("mine", turn: 1), log: log,
            slot: CheckSlot(project: fx.project, threadID: "mine", max: 2)
        ) { _ in }
        await log.close()

        #expect(report.result == .failed)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the command was not started")
        let events = try fx.events("mine")
        #expect(events.map(\.kind.rawValue) == ["check.started", "check.ran"], "started and ended, as ever")
        let error = events.last?.data["error"]?.stringValue ?? ""
        #expect(error.contains("other-a") && error.contains("other-b"), "\(error)")
        let output = try String(contentsOf: fx.project.checkOutputURL("mine", turn: 1), encoding: .utf8)
        #expect(output.contains("max_concurrent_checks"))
    }
}
