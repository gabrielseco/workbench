import Foundation
import Testing

@testable import WorkbenchCore

/// Isolated from the machine's git config, so results do not depend on who runs the tests.
private func testGit(timeout: TimeInterval = 30) throws -> GitRunner {
    try GitRunner.discover(
        extraEnvironment: [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
        ], timeout: timeout)
}

private struct TestRepo {
    let root: URL
    let git: GitRunner

    init() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wb-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
        git = try testGit()
        try await run("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        try await run("add", "-A")
        try await run("commit", "-q", "-m", "first")
    }

    @discardableResult
    func run(_ args: String...) async throws -> GitResult {
        let result = try await git.run(args, in: root)
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
        return result
    }

    func write(_ name: String, _ content: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func head(_ ref: String = "HEAD") async throws -> String {
        try await run("rev-parse", ref).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var manager: WorktreeManager { WorktreeManager(repoRoot: root, git: git) }
}

@Suite struct GitRunnerTests {
    @Test func capturesStatusStdoutAndStderr() async throws {
        let sh = GitRunner(executable: URL(fileURLWithPath: "/bin/sh"), environment: ["PATH": "/usr/bin:/bin"])
        let result = try await sh.run(["-c", "echo out; echo err >&2; exit 3"], in: URL(fileURLWithPath: "/tmp"))
        #expect(result.status == 3)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(!result.succeeded)
    }

    @Test func timeoutKillsAndThrows() async throws {
        let sleep = GitRunner(
            executable: URL(fileURLWithPath: "/bin/sleep"), environment: [:], timeout: 0.3)
        let started = Date()
        await #expect(throws: GitError.timedOut(arguments: ["30"], seconds: 0.3)) {
            _ = try await sleep.run(["30"], in: URL(fileURLWithPath: "/tmp"))
        }
        #expect(Date().timeIntervalSince(started) < 25, "ended by the timeout, not by `sleep 30`")
    }

    @Test func aProcessThatIgnoresSigtermIsStillKilled() async throws {
        let sh = GitRunner(
            executable: URL(fileURLWithPath: "/bin/sh"), environment: ["PATH": "/usr/bin:/bin"], timeout: 0.3)
        let started = Date()
        await #expect(throws: GitError.self) {
            _ = try await sh.run(["-c", "trap '' TERM; while :; do sleep 1; done"], in: URL(fileURLWithPath: "/tmp"))
        }
        #expect(Date().timeIntervalSince(started) < Patience.limit)
    }

    @Test func standardInputIsClosed() async throws {
        // `cat` returns immediately only if stdin is /dev/null; otherwise this would hit the timeout.
        let cat = GitRunner(executable: URL(fileURLWithPath: "/bin/cat"), environment: [:], timeout: 5)
        let result = try await cat.run([], in: URL(fileURLWithPath: "/tmp"))
        #expect(result.succeeded)
        #expect(result.stdout.isEmpty)
    }

    @Test func outputIsCapped() async throws {
        let sh = GitRunner(executable: URL(fileURLWithPath: "/bin/sh"), environment: ["PATH": "/usr/bin:/bin"])
        let result = try await sh.run(
            ["-c", "head -c 6000000 /dev/zero | tr '\\0' x"], in: URL(fileURLWithPath: "/tmp"))
        #expect(result.stdout.utf8.count == GitRunner.outputLimit)
        #expect(result.outputTruncated, "a cut is reported, not silent")
    }

    @Test func outputUnderTheCapIsNotMarkedTruncated() async throws {
        let sh = GitRunner(executable: URL(fileURLWithPath: "/bin/sh"), environment: ["PATH": "/usr/bin:/bin"])
        let exact = try await sh.run(
            ["-c", "head -c \(GitRunner.outputLimit) /dev/zero | tr '\\0' x"], in: URL(fileURLWithPath: "/tmp"))
        #expect(exact.stdout.utf8.count == GitRunner.outputLimit && !exact.outputTruncated)
        #expect(!(try await sh.run(["-c", "echo hi"], in: URL(fileURLWithPath: "/tmp"))).outputTruncated)
    }

    @Test func missingExecutableIsALaunchError() async {
        let runner = GitRunner(executable: URL(fileURLWithPath: "/nonexistent/git"), environment: [:])
        await #expect(throws: GitError.self) {
            _ = try await runner.run(["status"], in: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func manyConcurrentRunsAllComplete() async throws {
        let sh = GitRunner(executable: URL(fileURLWithPath: "/bin/sh"), environment: ["PATH": "/usr/bin:/bin"])
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<40 {
                group.addTask {
                    try await sh.run(["-c", "echo \(i)"], in: URL(fileURLWithPath: "/tmp")).stdout
                }
            }
            var seen = Set<String>()
            for try await out in group { seen.insert(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
            #expect(seen.count == 40)
        }
    }
}

@Suite struct WorktreeCreateTests {
    @Test func createsWorktreeOnADeterministicBranchAtBase() async throws {
        let repo = try await TestRepo()
        let worktree = try await repo.manager.create(threadID: "t1", base: "main")

        #expect(worktree.path.path == repo.root.appendingPathComponent(".workbench/worktrees/t1").path)
        #expect(worktree.branch == "workbench/t1")
        #expect(worktree.baseCommit == (try await repo.head("main")))
        #expect(try String(contentsOf: worktree.path.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        #expect(repo.manager.exists("t1"))

        let branchHead = try await repo.head("workbench/t1")
        #expect(branchHead == worktree.baseCommit)
        let current = try await testGit().run(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree.path)
        #expect(current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "workbench/t1")
    }

    @Test func cutsFromBaseNotFromWhateverIsCheckedOut() async throws {
        let repo = try await TestRepo()
        let mainCommit = try await repo.head()
        try await repo.run("checkout", "-q", "-b", "other")
        try repo.write("b.txt", "other branch\n")
        try await repo.run("add", "-A")
        try await repo.run("commit", "-q", "-m", "other")

        let worktree = try await repo.manager.create(threadID: "t1", base: "main")
        #expect(worktree.baseCommit == mainCommit)
        #expect(!FileManager.default.fileExists(atPath: worktree.path.appendingPathComponent("b.txt").path))
    }

    @Test func keepsWorkbenchOutOfStatusWithoutTouchingGitignore() async throws {
        let repo = try await TestRepo()
        _ = try await repo.manager.create(threadID: "t1", base: "main")
        try repo.write(".workbench/threads/t1/events.jsonl", "{}\n")

        let status = try await repo.run("status", "--porcelain")
        #expect(status.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(".gitignore").path))

        // Idempotent.
        try await repo.manager.remove(threadID: "t1", deleteBranch: true)
        _ = try await repo.manager.create(threadID: "t2", base: "main")
        let exclude = try String(
            contentsOf: repo.root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: ".workbench/").count == 2)
    }

    @Test func aTrackedChangeInTheCheckoutDoesNotBlockAndStaysOutOfTheWorktree() async throws {
        let repo = try await TestRepo()
        try repo.write("a.txt", "edited\n")
        #expect(try await repo.manager.checkoutChanges() == [" M a.txt"])

        let worktree = try await repo.manager.create(threadID: "t1", base: "main")
        // The worktree is the committed state, not the uncommitted edit; the checkout keeps its edit.
        #expect(try String(contentsOf: worktree.path.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        #expect(try String(contentsOf: repo.root.appendingPathComponent("a.txt"), encoding: .utf8) == "edited\n")
    }

    @Test func excludeWorkbenchIsOnceAndSkippedWhenAlreadyIgnored() async throws {
        let repo = try await TestRepo()
        try await repo.manager.excludeWorkbench()
        try await repo.manager.excludeWorkbench()
        let exclude = try String(
            contentsOf: repo.root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: ".workbench/").count == 2)
        try repo.write(".workbench/config.toml", "x\n")
        #expect(try await repo.run("status", "--porcelain").stdout.isEmpty)

        let other = try await TestRepo()
        try other.write(".gitignore", ".workbench\n")
        try await other.manager.excludeWorkbench()
        let none = try? String(contentsOf: other.root.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(none?.contains(".workbench/") != true, "already ignored, so nothing was added")
    }

    @Test func theBaseGapCountsCommitsBehindOriginAndSaysNothingWithoutOne() async throws {
        let repo = try await TestRepo()
        #expect(await repo.manager.baseGap(base: "main") == nil, "no origin")

        let bare = repo.root.deletingLastPathComponent().appendingPathComponent("o-\(UUID().uuidString).git")
        _ = try await repo.git.run(["init", "-q", "--bare", bare.path], in: repo.root)
        try await repo.run("remote", "add", "origin", bare.path)
        try await repo.run("push", "-q", "origin", "main")
        #expect(await repo.manager.baseGap(base: "main") == WorktreeManager.BaseGap(base: "main", behind: 0, fetchNote: nil))

        // Someone else moves origin/main two commits ahead.
        let clone = repo.root.deletingLastPathComponent().appendingPathComponent("c-\(UUID().uuidString)")
        _ = try await repo.git.run(["clone", "-q", "-b", "main", bare.path, clone.path], in: repo.root)
        for n in 1...2 {
            try "\(n)\n".write(to: clone.appendingPathComponent("n\(n).txt"), atomically: true, encoding: .utf8)
            _ = try await repo.git.run(["add", "-A"], in: clone)
            _ = try await repo.git.run(["commit", "-q", "-m", "n\(n)"], in: clone)
        }
        let pushed = try await repo.git.run(["push", "-q", "origin", "HEAD:main"], in: clone)
        #expect(pushed.succeeded, "\(pushed.stderr)")

        let before = try await repo.head("main")
        let gap = await repo.manager.baseGap(base: "main")
        #expect(gap == WorktreeManager.BaseGap(base: "main", behind: 2, fetchNote: nil))
        #expect(try await repo.head("main") == before, "the local branch is untouched")
        let worktree = try await repo.manager.create(threadID: "t1", base: "main")
        #expect(worktree.baseCommit == before, "still cut from the local base")
    }

    @Test func whenTheFetchFailsTheKnownOriginRefIsStillCompared() async throws {
        let repo = try await TestRepo()
        let bare = repo.root.deletingLastPathComponent().appendingPathComponent("k-\(UUID().uuidString).git")
        _ = try await repo.git.run(["init", "-q", "--bare", bare.path], in: repo.root)
        try await repo.run("remote", "add", "origin", bare.path)
        try await repo.run("push", "-q", "origin", "main")
        // origin/main is ahead by one, as far as this clone knows.
        try repo.write("b.txt", "b\n")
        try await repo.run("add", "-A")
        try await repo.run("commit", "-q", "-m", "b")
        try await repo.run("push", "-q", "origin", "main")
        try await repo.run("reset", "-q", "--hard", "HEAD~1")
        // Then the origin goes away.
        try FileManager.default.removeItem(at: bare)

        let gap = await repo.manager.baseGap(base: "main")
        #expect(gap?.behind == 1, "\(String(describing: gap))")
        #expect(gap?.fetchNote?.contains("could not fetch origin") == true)
    }

    @Test func anUnreachableOrHungOriginIsANoteNotAnError() async throws {
        let repo = try await TestRepo()
        try await repo.run("remote", "add", "origin", "/nonexistent/origin.git")
        let gone = await repo.manager.baseGap(base: "main")
        #expect(gone?.behind == 0)
        #expect(gone?.fetchNote?.contains("could not fetch origin") == true, "\(String(describing: gone))")

        let bare = repo.root.deletingLastPathComponent().appendingPathComponent("h-\(UUID().uuidString).git")
        _ = try await repo.git.run(["init", "-q", "--bare", bare.path], in: repo.root)
        let hang = bare.appendingPathExtension("sh")
        try "#!/bin/sh\nexec sleep 60\n".write(to: hang, atomically: true, encoding: .utf8)
        chmod(hang.path, 0o755)
        try await repo.run("remote", "set-url", "origin", bare.path)
        try await repo.run("config", "remote.origin.uploadpack", hang.path)
        let started = Date()
        let slow = await repo.manager.baseGap(base: "main", fetchTimeout: 2)
        #expect(Date().timeIntervalSince(started) < 45, "ended by the fetch timeout, not by `sleep 60`")
        #expect(slow?.fetchNote?.contains("no answer") == true, "\(String(describing: slow))")
    }

    @Test func untrackedFilesDoNotCountAsDirty() async throws {
        let repo = try await TestRepo()
        try repo.write("scratch.txt", "notes\n")
        try repo.write(".workbench/threads/x/goal.md", "goal\n")
        _ = try await repo.manager.create(threadID: "t1", base: "main")
    }

    @Test func notARepositoryAndMissingDirectory() async throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("wb-plain-\(UUID())")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let git = try testGit()

        await #expect(throws: WorktreeError.notAGitRepository(plain.resolvingSymlinksInPath().path)) {
            _ = try await WorktreeManager(repoRoot: plain, git: git).create(threadID: "t1", base: "main")
        }
        let missing = plain.appendingPathComponent("does-not-exist")
        await #expect(throws: WorktreeError.self) {
            _ = try await WorktreeManager(repoRoot: missing, git: git).create(threadID: "t1", base: "main")
        }
    }

    @Test func subdirectoryOfARepositoryIsNotTheRoot() async throws {
        let repo = try await TestRepo()
        try repo.write("sub/file.txt", "x\n")
        try await repo.run("add", "-A")
        try await repo.run("commit", "-q", "-m", "sub")
        let sub = repo.root.appendingPathComponent("sub")
        await #expect(throws: WorktreeError.notAGitRepository(sub.path)) {
            _ = try await WorktreeManager(repoRoot: sub, git: repo.git).create(threadID: "t1", base: "main")
        }
    }

    @Test func unknownBase() async throws {
        let repo = try await TestRepo()
        await #expect(throws: WorktreeError.baseNotFound("nope")) {
            _ = try await repo.manager.create(threadID: "t1", base: "nope")
        }
    }

    @Test func duplicateWorktreeAndStrayBranch() async throws {
        let repo = try await TestRepo()
        _ = try await repo.manager.create(threadID: "t1", base: "main")
        let path = repo.root.appendingPathComponent(".workbench/worktrees/t1").path
        await #expect(throws: WorktreeError.worktreeExists(path)) {
            _ = try await repo.manager.create(threadID: "t1", base: "main")
        }

        try await repo.run("branch", "workbench/t2", "main")
        await #expect(throws: WorktreeError.branchExists("workbench/t2")) {
            _ = try await repo.manager.create(threadID: "t2", base: "main")
        }
    }

    @Test(arguments: ["../escape", "a/b", "-rf", "has space", ".hidden", "", "x.lock"])
    func unsafeThreadIDsNeverReachGit(id: String) async throws {
        let repo = try await TestRepo()
        await #expect(throws: WorktreeError.invalidThreadID(id)) {
            _ = try await repo.manager.create(threadID: id, base: "main")
        }
    }

    @Test(arguments: ["--upload-pack=x", "-main", "a..b", "has space", "a//b", "trailing/"])
    func unsafeBasesNeverReachGit(base: String) async throws {
        let repo = try await TestRepo()
        await #expect(throws: WorktreeError.invalidBase(base)) {
            _ = try await repo.manager.create(threadID: "t1", base: base)
        }
    }

    @Test func aWorktreeDeletedByHandDoesNotBlockRecreating() async throws {
        let repo = try await TestRepo()
        let first = try await repo.manager.create(threadID: "t1", base: "main")
        // Directory gone, git still has it registered, branch removed by other means.
        try FileManager.default.removeItem(at: first.path)
        try await repo.run("update-ref", "-d", "refs/heads/workbench/t1")

        let again = try await repo.manager.create(threadID: "t1", base: "main")
        #expect(again.path.path == first.path.path)
    }
}

@Suite struct WorktreeRemoveTests {
    @Test func removeKeepsTheBranchByDefault() async throws {
        let repo = try await TestRepo()
        let worktree = try await repo.manager.create(threadID: "t1", base: "main")
        try await repo.manager.remove(threadID: "t1")

        #expect(!FileManager.default.fileExists(atPath: worktree.path.path))
        #expect(!repo.manager.exists("t1"))
        _ = try await repo.head("workbench/t1")  // still there
    }

    @Test func removeCanDeleteTheBranch() async throws {
        let repo = try await TestRepo()
        _ = try await repo.manager.create(threadID: "t1", base: "main")
        try await repo.manager.remove(threadID: "t1", deleteBranch: true)

        let probe = try await repo.git.run(["show-ref", "--verify", "--quiet", "refs/heads/workbench/t1"], in: repo.root)
        #expect(!probe.succeeded)
        #expect(try await repo.run("worktree", "list", "--porcelain").stdout.contains("workbench/t1") == false)
    }

    @Test func removeRefusesUncommittedWorkUnlessForced() async throws {
        let repo = try await TestRepo()
        let worktree = try await repo.manager.create(threadID: "t1", base: "main")
        try "wip\n".write(to: worktree.path.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        #expect(try await repo.manager.changes(in: "t1") == ["?? new.txt"])

        do {
            try await repo.manager.remove(threadID: "t1")
            Issue.record("expected gitFailed")
        } catch let error as WorktreeError {
            guard case .gitFailed(let command, _, _) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(command == "worktree remove")
        }
        #expect(repo.manager.exists("t1"))

        try await repo.manager.remove(threadID: "t1", force: true)
        #expect(!repo.manager.exists("t1"))
    }

    @Test func removeUnknownThread() async throws {
        let repo = try await TestRepo()
        let path = repo.root.appendingPathComponent(".workbench/worktrees/ghost").path
        await #expect(throws: WorktreeError.worktreeNotFound(path)) {
            try await repo.manager.remove(threadID: "ghost")
        }
    }

    @Test func createRemoveCycleLeavesTheRepositoryClean() async throws {
        let repo = try await TestRepo()
        let before = try await repo.head()
        for i in 0..<5 {
            _ = try await repo.manager.create(threadID: "cycle-\(i)", base: "main")
            try await repo.manager.remove(threadID: "cycle-\(i)", deleteBranch: true)
        }
        #expect(try await repo.head() == before)
        #expect(try await repo.run("status", "--porcelain").stdout.isEmpty)
        let list = try await repo.run("worktree", "list", "--porcelain").stdout
        #expect(list.components(separatedBy: "worktree ").count == 2)  // only the main checkout
        let branches = try await repo.run("branch", "--list").stdout
        #expect(!branches.contains("workbench/"))
    }
}

@Suite struct WorktreeCopyTests {
    private func ignoringEnv() async throws -> TestRepo {
        let repo = try await TestRepo()
        try repo.write(".gitignore", ".env*\nexample/.env\nbig.env\n")
        try await repo.run("add", "-A")
        try await repo.run("commit", "-q", "-m", "ignore env")
        return repo
    }

    @Test func copiesIgnoredFilesThatMatchAndKeepsThemOutOfStatus() async throws {
        let repo = try await ignoringEnv()
        try repo.write(".env.local", "A=1\n")
        try repo.write(".env.test", "B=2\n")
        try repo.write("example/.env", "C=3\n")
        let tree = try await repo.manager.create(
            threadID: "t1", base: "main", copying: [".env.*", "example/.env"])
        #expect(tree.copy.copied == [".env.local", ".env.test", "example/.env"])
        #expect(tree.copy.skipped.isEmpty)
        #expect(try String(contentsOf: tree.path.appendingPathComponent("example/.env"), encoding: .utf8) == "C=3\n")
        #expect(try await repo.manager.changes(in: "t1").isEmpty)
    }

    @Test func aGlobInADirectoryComponentMatches() async throws {
        let repo = try await ignoringEnv()
        try repo.write("example/.env", "C=3\n")
        let tree = try await repo.manager.create(threadID: "t1", base: "main", copying: ["*/.env"])
        #expect(tree.copy.copied == ["example/.env"])
    }

    @Test func aFileGitDoesNotIgnoreIsNotCopiedAndSaysWhy() async throws {
        let repo = try await ignoringEnv()
        try repo.write("notes.txt", "mine\n")
        let tree = try await repo.manager.create(threadID: "t1", base: "main", copying: ["notes.txt"])
        #expect(tree.copy.copied.isEmpty)
        #expect(tree.copy.skipped.count == 1 && tree.copy.skipped[0].contains("not ignored"))
        #expect(!FileManager.default.fileExists(atPath: tree.path.appendingPathComponent("notes.txt").path))
    }

    @Test func aPatternThatMatchesNothingIsReportedNotFatal() async throws {
        let repo = try await ignoringEnv()
        let tree = try await repo.manager.create(threadID: "t1", base: "main", copying: [".env.*"])
        #expect(tree.copy.copied.isEmpty)
        #expect(tree.copy.skipped == [".env.*: no file matches"])
    }

    @Test func aSymlinkIsNeverFollowed() async throws {
        let repo = try await ignoringEnv()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("wb-secret-\(UUID().uuidString)")
        try "secret\n".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: repo.root.appendingPathComponent(".env.link"), withDestinationURL: outside)
        let tree = try await repo.manager.create(threadID: "t1", base: "main", copying: [".env.*"])
        #expect(tree.copy.copied.isEmpty)
        #expect(tree.copy.skipped.first?.contains("not a regular file") == true)
        #expect(!FileManager.default.fileExists(atPath: tree.path.appendingPathComponent(".env.link").path))
    }

    @Test func aFileOverTheSizeCapIsSkipped() async throws {
        let repo = try await ignoringEnv()
        try repo.write("big.env", String(repeating: "x", count: WorktreeCopier.maxFileBytes + 1))
        let tree = try await repo.manager.create(threadID: "t1", base: "main", copying: ["big.env"])
        #expect(tree.copy.copied.isEmpty)
        #expect(tree.copy.skipped.first?.contains("larger than") == true)
    }

    @Test func withNoPatternsNothingIsCopied() async throws {
        let repo = try await ignoringEnv()
        try repo.write(".env.local", "A=1\n")
        let tree = try await repo.manager.create(threadID: "t1", base: "main")
        #expect(tree.copy == CopyReport())
        #expect(!FileManager.default.fileExists(atPath: tree.path.appendingPathComponent(".env.local").path))
    }

    @Test func aSymlinkedFolderInTheWorktreeIsNotWrittenThrough() async throws {
        let repo = try await TestRepo()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("wb-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try repo.write(".gitignore", ".env\n")
        try FileManager.default.createSymbolicLink(
            at: repo.root.appendingPathComponent("example"), withDestinationURL: outside)
        try await repo.run("add", "-A")
        try await repo.run("commit", "-q", "-m", "example is a link")
        // The checkout has a real folder there (uncommitted), the base has a link.
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("example"))
        try repo.write("example/.env", "S=1\n")
        let tree = try await repo.manager.create(threadID: "t1", base: "main", copying: ["example/.env"])
        #expect(tree.copy.copied.isEmpty)
        #expect(tree.copy.skipped.first?.contains("symlink") == true)
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent(".env").path))
    }

    @Test func aFileOnlyTheCheckoutIgnoresIsNotCopied() async throws {
        let repo = try await TestRepo()
        try repo.write(".gitignore", ".env.local\n")  // not committed: the base does not have this rule
        try repo.write(".env.local", "A=1\n")
        let tree = try await repo.manager.create(threadID: "t1", base: "main", copying: [".env.local"])
        #expect(tree.copy.copied.isEmpty)
        #expect(tree.copy.skipped.first?.contains("not ignored") == true)
        #expect(!FileManager.default.fileExists(atPath: tree.path.appendingPathComponent(".env.local").path))
    }

    @Test func aWideGlobStopsAtTheCapWithOneAggregateNote() async throws {
        let repo = try await TestRepo()
        for i in 0..<60 { try repo.write("many/f\(i)", "x") }
        let tree = try await repo.manager.create(threadID: "t1", base: "main")
        var copier = WorktreeCopier(source: repo.root, git: repo.git)
        copier.maxMatches = 40
        let report = await copier.copy(["many/*"], to: tree.path)
        #expect(report.copied.isEmpty)
        // 20 notes, one that the glob stopped, one aggregate; never one note per match.
        #expect(report.skipped.count <= WorktreeCopier.maxNotes + 1)
        #expect(report.skipped.last?.hasPrefix("and ") == true)
    }

    @Test func theConfigKeyRejectsPathsThatLeaveTheRepository() throws {
        func parse(_ line: String) throws -> Config {
            try Config.parse("\(line)\n[tools]\navailable = [\"Read\"]\n")
        }
        #expect(try parse("copy = [\".env.*\", \"example/.env\"]").copy == [".env.*", "example/.env"])
        #expect(try parse("").copy.isEmpty)
        for bad in ["/etc/passwd", "~/.ssh/id_rsa", "../.env", "a/../b", "-x", "", ".git/config", ".workbench/x", "a//b"] {
            #expect(throws: ConfigError.self, "\(bad)") { try parse("copy = [\"\(bad)\"]") }
        }
        #expect(throws: ConfigError.self) { try parse("copy = \".env\"") }
    }
}
