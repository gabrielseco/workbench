import Foundation
import Testing

@testable import WorkbenchCore

private func branchExists(_ id: String, _ fx: RunnerFixture) async throws -> Bool {
    try await fx.git.run(["rev-parse", "--verify", "--quiet", "refs/heads/workbench/\(id)"], in: fx.repo)
        .succeeded
}

/// A thread that has run once, with one committed file and an untouched checkout otherwise.
private func workedThread(_ fx: RunnerFixture) async throws -> (id: String, worktree: URL) {
    let id = try await fx.approvedThread()
    _ = try await fx.runner(id).run(fx.options())
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    try "tracked\n".write(to: worktree.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    _ = try await fx.git.run(["add", "tracked.txt"], in: worktree)
    _ = try await fx.git.run(["commit", "-q", "-m", "model work"], in: worktree)
    return (id, worktree)
}

private func write(_ text: String, _ name: String, in worktree: URL) throws {
    try text.write(to: worktree.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

private func patchURL(_ id: String, _ fx: RunnerFixture) -> URL {
    fx.project.threadDirectory(id).appendingPathComponent(ThreadService.abandonPatchName)
}

/// The patch applied to a fresh checkout of the branch tip, which is where it is meant to go.
private func apply(_ patch: URL, to id: String, _ fx: RunnerFixture) async throws -> URL {
    let checkout = FileManager.default.temporaryDirectory.appendingPathComponent("abandon-apply-\(UUID().uuidString)")
    _ = try await fx.git.run(["worktree", "add", "--detach", checkout.path, "refs/heads/workbench/\(id)"], in: fx.repo)
    let applied = try await fx.git.run(["apply", "--binary", patch.path], in: checkout)
    #expect(applied.succeeded, "git apply: \(applied.stderr)")
    return checkout
}

@Suite(.processGate) struct AbandonSavesChangesTests {
    @Test func aDirtyWorktreeIsSavedThenRemovedAndTheBranchIsKept() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("changed\n", "tracked.txt", in: worktree)
        try write("new\n", "untracked.txt", in: worktree)
        try write("staged\n", "staged.txt", in: worktree)
        _ = try await fx.git.run(["add", "staged.txt"], in: worktree)

        let saved = try #require(try await fx.service.abandon(id: id))

        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try await branchExists(id, fx))
        #expect(saved.url == patchURL(id, fx))
        #expect(FileManager.default.fileExists(atPath: saved.url.path))
        let checkout = try await apply(saved.url, to: id, fx)
        defer { try? FileManager.default.removeItem(at: checkout) }
        #expect(try String(contentsOf: checkout.appendingPathComponent("tracked.txt"), encoding: .utf8) == "changed\n")
        #expect(try String(contentsOf: checkout.appendingPathComponent("untracked.txt"), encoding: .utf8) == "new\n")
        #expect(try String(contentsOf: checkout.appendingPathComponent("staged.txt"), encoding: .utf8) == "staged\n")
    }

    @Test func theLogRecordsThePatchBeforeTheDecision() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("loose\n", "loose.txt", in: worktree)

        let saved = try #require(try await fx.service.abandon(id: id))

        let events = try fx.events(id)
        let kinds = events.suffix(2).map(\.kind)
        #expect(kinds == [.abandonSaved, .reviewDecision])
        let event = try #require(events.last { $0.kind == .abandonSaved })
        #expect(event.data["path"]?.stringValue == "abandon.patch")
        #expect(event.data["sha256"]?.stringValue == saved.sha256)
        #expect(event.data["bytes"]?.intValue == saved.bytes)
        #expect(event.data["head"]?.stringValue == saved.head)
        #expect(event.data["tree"]?.stringValue == saved.tree)
        #expect(events.last?.data["decision"]?.stringValue == "abandoned")
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func aBinaryFileSurvivesTheRoundTrip() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) } + [0, 255, 0, 128])
        try bytes.write(to: worktree.appendingPathComponent("blob.bin"))

        let saved = try #require(try await fx.service.abandon(id: id))

        let checkout = try await apply(saved.url, to: id, fx)
        defer { try? FileManager.default.removeItem(at: checkout) }
        #expect(try Data(contentsOf: checkout.appendingPathComponent("blob.bin")) == bytes)
    }

    @Test func aCleanWorktreeIsRemovedWithNoPatchAndNoEvent() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)

        let saved = try await fx.service.abandon(id: id)

        #expect(saved == nil)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(!FileManager.default.fileExists(atPath: patchURL(id, fx).path))
        #expect(try !fx.events(id).contains { $0.kind == .abandonSaved })
        #expect(try fx.events(id).last?.data["decision"]?.stringValue == "abandoned")
    }

    @Test func ignoredFilesAreNeitherSavedNorInTheWay() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("build/\n", ".gitignore", in: worktree)
        _ = try await fx.git.run(["add", ".gitignore"], in: worktree)
        _ = try await fx.git.run(["commit", "-q", "-m", "ignore build"], in: worktree)
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("build"), withIntermediateDirectories: true)
        try write("output\n", "build/out.txt", in: worktree)

        let saved = try await fx.service.abandon(id: id)

        #expect(saved == nil, "only ignored files were left, so there is nothing to keep")
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func theWorktreesOwnIndexAndHistoryAreUntouchedWhileSaving() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("new\n", "untracked.txt", in: worktree)
        let before = try await fx.git.run(["rev-parse", "HEAD"], in: worktree).stdout
        let patch = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: patch) }

        _ = try await WorktreePatch.save(
            worktree: worktree, to: patch, stagedTo: patch.appendingPathExtension("staged"), git: fx.git,
            attributesFrom: nil)

        #expect(try await fx.git.run(["rev-parse", "HEAD"], in: worktree).stdout == before)
        let status = try await fx.git.run(["status", "--porcelain"], in: worktree).stdout
        #expect(status.contains("?? untracked.txt"), "still untracked, not added to the real index: \(status)")
        _ = id
    }

    @Test func aPatchThatCannotBeWrittenRefusesAndRemovesNothing() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("keep me\n", "loose.txt", in: worktree)
        let folder = fx.project.threadDirectory(id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        await #expect(throws: ThreadServiceError.self) { try await fx.service.abandon(id: id) }

        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("loose.txt").path))
        #expect(try await branchExists(id, fx))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(try fx.events(id).last?.kind != .reviewDecision, "the thread is still active")
    }

    @Test func aWorktreeOverTheLimitRefusesBeforeWritingAndRemovesNothing() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("small\n", "small.txt", in: worktree)
        let big = worktree.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(WorktreePatch.sizeLimit + 1))
        try handle.close()

        do {
            _ = try await fx.service.abandon(id: id)
            Issue.record("expected a refusal")
        } catch let error as ThreadServiceError {
            #expect(error.description.contains("discard"), "says what to do: \(error)")
            #expect(error.description.contains("Nothing was removed"))
        }

        #expect(FileManager.default.fileExists(atPath: big.path))
        #expect(!FileManager.default.fileExists(atPath: patchURL(id, fx).path), "no partial patch is left")
        #expect(try await branchExists(id, fx))
    }

    @Test func aLiveRunIsRefusedAndNothingIsSavedOrRemoved() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("loose\n", "loose.txt", in: worktree)
        let me = getpid()
        let started = try #require(ProcessTree.member(for: me))
        let info: [String: Any] = [
            "pid": me, "started_seconds": started.startSeconds, "started_micros": started.startMicros,
        ]
        try JSONSerialization.data(withJSONObject: info).write(to: fx.project.runnerURL(id))

        await #expect(throws: ThreadServiceError.running(pid: me)) { try await fx.service.abandon(id: id) }

        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("loose.txt").path))
        #expect(!FileManager.default.fileExists(atPath: patchURL(id, fx).path))
        try FileManager.default.removeItem(at: fx.project.runnerURL(id))
    }

    /// What stands in for git's own refusal: the tree read again before removing must be the one the patch holds.
    @Test func theSavedTreeIsTheWorktreesUntilSomethingIsWrittenAfterIt() async throws {
        let fx = try await RunnerFixture()
        let (_, worktree) = try await workedThread(fx)
        try write("loose\n", "loose.txt", in: worktree)
        let patch = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: patch) }

        let saved = try #require(try await WorktreePatch.save(
            worktree: worktree, to: patch, stagedTo: patch.appendingPathExtension("staged"), git: fx.git, attributesFrom: nil))
        let same = await ProofIdentity.of(worktree: worktree, git: fx.git, attributesFrom: nil)
        #expect(same?.tree == saved.tree)

        try write("written after the save\n", "late.txt", in: worktree)
        let later = await ProofIdentity.of(worktree: worktree, git: fx.git, attributesFrom: nil)
        #expect(later?.tree != saved.tree)
    }

    @Test func aFileWrittenAfterTheSaveRefusesTheAbandonAndRemovesNothing() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("loose\n", "loose.txt", in: worktree)

        await #expect(throws: ThreadServiceError.self) {
            _ = try await fx.service.abandon(id: id, force: false) {
                try "late\n".write(to: worktree.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
            }
        }

        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("late.txt").path))
        #expect(try fx.events(id).last?.kind != .reviewDecision, "the thread is still active")
    }

    private func stagedPatchURL(_ id: String, _ fx: RunnerFixture) -> URL {
        fx.project.threadDirectory(id).appendingPathComponent(ThreadService.abandonStagedPatchName)
    }

    @Test func aStagedVersionThatWasEditedAgainIsKeptInASecondPatch() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("version A\n", "tracked.txt", in: worktree)
        _ = try await fx.git.run(["add", "tracked.txt"], in: worktree)
        try write("version B\n", "tracked.txt", in: worktree)

        let saved = try #require(try await fx.service.abandon(id: id))

        let staged = try #require(saved.staged, "the index held something the working tree does not")
        #expect(staged.url == stagedPatchURL(id, fx))
        let working = try await apply(saved.url, to: id, fx)
        defer { try? FileManager.default.removeItem(at: working) }
        #expect(try String(contentsOf: working.appendingPathComponent("tracked.txt"), encoding: .utf8) == "version B\n")
        let index = try await apply(staged.url, to: id, fx)
        defer { try? FileManager.default.removeItem(at: index) }
        #expect(try String(contentsOf: index.appendingPathComponent("tracked.txt"), encoding: .utf8) == "version A\n")
        let event = try #require(try fx.events(id).last { $0.kind == .abandonSaved })
        #expect(event.data["staged_path"]?.stringValue == "abandon-staged.patch")
        #expect(event.data["staged_sha256"]?.stringValue == staged.sha256)
    }

    @Test func aFileStagedAsAddedAndThenDeletedFromDiskIsKeptInTheSecondPatch() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("only in the index\n", "staged-only.txt", in: worktree)
        _ = try await fx.git.run(["add", "staged-only.txt"], in: worktree)
        try FileManager.default.removeItem(at: worktree.appendingPathComponent("staged-only.txt"))
        try write("changed\n", "tracked.txt", in: worktree)

        let saved = try #require(try await fx.service.abandon(id: id))

        let staged = try #require(saved.staged)
        let index = try await apply(staged.url, to: id, fx)
        defer { try? FileManager.default.removeItem(at: index) }
        #expect(
            try String(contentsOf: index.appendingPathComponent("staged-only.txt"), encoding: .utf8)
                == "only in the index\n")
    }

    @Test func aStagedRenameThenDeletedFromDiskIsKept() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        _ = try await fx.git.run(["mv", "tracked.txt", "renamed.txt"], in: worktree)
        try FileManager.default.removeItem(at: worktree.appendingPathComponent("renamed.txt"))

        let saved = try #require(try await fx.service.abandon(id: id))

        let staged = try #require(saved.staged)
        let index = try await apply(staged.url, to: id, fx)
        defer { try? FileManager.default.removeItem(at: index) }
        #expect(FileManager.default.fileExists(atPath: index.appendingPathComponent("renamed.txt").path))
    }

    @Test func noSecondPatchWhenTheIndexMatchesTheWorkingTree() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("staged and left alone\n", "staged.txt", in: worktree)
        _ = try await fx.git.run(["add", "staged.txt"], in: worktree)
        try write("loose\n", "loose.txt", in: worktree)

        let saved = try #require(try await fx.service.abandon(id: id))

        #expect(saved.staged == nil, "everything staged is already what the working tree holds")
        #expect(!FileManager.default.fileExists(atPath: stagedPatchURL(id, fx).path))
    }

    @Test func theAbandonIsOnRecordBeforeTheWorktreeGoesSoARetryAfterACrashKeepsIt() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("loose\n", "loose.txt", in: worktree)
        let stuck = worktree.appendingPathComponent("stuck")
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try write("x\n", "stuck/file.txt", in: worktree)
        _ = try await fx.git.run(["add", "stuck/file.txt"], in: worktree)
        _ = try await fx.git.run(["commit", "-q", "-m", "stuck"], in: worktree)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuck.path) }

        await #expect(throws: (any Error).self) { try await fx.service.abandon(id: id) }

        let events = try fx.events(id)
        #expect(events.contains { $0.kind == .abandonSaved }, "recorded before the removal that failed")
        #expect(events.last?.kind != .reviewDecision, "still active, so a retry can finish")
    }

    @Test func childrenTheRunnerLeftInTheWorktreeAreSweptBeforeTheChangesAreSaved() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("loose\n", "loose.txt", in: worktree)
        let null = open("/dev/null", O_WRONLY)
        defer { close(null) }
        let sh = try Spawner.spawn(
            executable: "/bin/sh", arguments: ["-c", "exec sleep 300 &"], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: worktree.path, stdout: null, stderr: null)
        var status: Int32 = 0
        waitpid(sh, &status, 0)
        var orphan: ProcessMember?
        let deadline = Date().addingTimeInterval(Patience.limit)
        while orphan == nil, Date() < deadline {
            orphan = OrphanSweeper.orphans(inside: worktree).first
            if orphan == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let member = try #require(orphan, "the helper should be orphaned and found by its cwd")
        defer { kill(member.pid, SIGKILL) }

        _ = try await fx.service.abandon(id: id)

        #expect(await FakeClaude.waitUntilGone(member.pid))
        #expect(try fx.kinds(id).contains("orphans.swept"))
    }

    @Test func theLogLockIsHeldForTheWholeAbandonSoANewRunCannotLoseItsWorktree() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("loose\n", "loose.txt", in: worktree)

        try await fx.service.withLog(id) { _ in
            await #expect(throws: (any Error).self) { try await fx.service.abandon(id: id) }
        }

        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("loose.txt").path))
        #expect(try fx.events(id).last?.kind != .reviewDecision)
    }

    @Test func aHugeUntrackedFileIsRefusedBeforeGitStoresIt() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        let big = worktree.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(WorktreePatch.sizeLimit + 1))
        try handle.close()
        func looseObjects() async throws -> String {
            let out = try await fx.git.run(["count-objects", "-v"], in: fx.repo).stdout
            return out.split(separator: "\n").first { $0.hasPrefix("count:") }.map(String.init) ?? out
        }
        let before = try await looseObjects()

        await #expect(throws: ThreadServiceError.self) { try await fx.service.abandon(id: id) }

        #expect(try await looseObjects() == before, "git add never ran on the oversized file")
    }

    @Test func aGitConfigWithNoPrefixStillGivesAPatchGitApplyTakes() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        _ = try await fx.git.run(["config", "diff.noprefix", "true"], in: fx.repo)
        try write("changed\n", "tracked.txt", in: worktree)

        let saved = try #require(try await fx.service.abandon(id: id))

        let checkout = try await apply(saved.url, to: id, fx)
        defer { try? FileManager.default.removeItem(at: checkout) }
        #expect(try String(contentsOf: checkout.appendingPathComponent("tracked.txt"), encoding: .utf8) == "changed\n")
    }

    @Test func abandoningTwiceIsRefusedAndKeepsTheFirstPatch() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("loose\n", "loose.txt", in: worktree)
        let first = try #require(try await fx.service.abandon(id: id))

        await #expect(throws: ThreadServiceError.self) { try await fx.service.abandon(id: id) }

        let digest = ProofCollector.sha256(of: patchURL(id, fx), limit: 1 << 20)
        #expect(digest?.hex == first.sha256)
    }

    @Test func theCommandSaysWhereTheChangesWentAndHowToGetThemBack() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await workedThread(fx)
        try write("loose\n", "loose.txt", in: worktree)
        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: ["abandon"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
            workingDirectory: fx.repo, timeout: 60)
        spawn.snapshotInterval = 3600
        let run = try ProcessRunner.start(spawn)
        var lines: [String] = []
        var exit: ProcessExit?
        for await event in run.events {
            if case .line(let line) = event { lines.append(line) }
            if case .exited(let e) = event { exit = e }
        }
        let text = lines.joined(separator: "\n")

        #expect(exit?.termination == .exited(0), "\(text)")
        #expect(text.contains("abandon.patch"), "\(text)")
        #expect(text.contains("git apply"), "\(text)")
        #expect(text.contains("workbench/\(id)"), "\(text)")
    }
}
