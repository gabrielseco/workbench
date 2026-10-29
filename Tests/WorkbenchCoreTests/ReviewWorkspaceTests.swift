import Foundation
import Testing

@testable import WorkbenchCore

/// A repo with a base commit, a worktree of it for the thread, and a folder outside both that nothing may write to.
private struct WorkspaceRig {
    let repo: URL
    let worktree: URL
    let outside: URL
    let destination: URL
    let base: String
    let git: GitRunner

    init(
        files: [String: String] = ["keep.txt": "keep\n", "edit.txt": "one\n", "drop.txt": "bye\n", "move.txt": "moved\n"]
    ) async throws {
        let dir = Scratch.url("reviewworkspace").resolvingSymlinksInPath()
        repo = dir.appendingPathComponent("repo")
        worktree = dir.appendingPathComponent("worktree")
        outside = dir.appendingPathComponent("outside")
        destination = dir.appendingPathComponent("thread").appendingPathComponent(ReviewWorkspace.folderName)
        git = try GitRunner.discover(
            extraEnvironment: [
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
            ], timeout: 60)
        for folder in [repo, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        _ = try await git.run(["init", "-q", "-b", "main"], in: repo)
        for (name, content) in files { try Self.write(repo, name, content) }
        _ = try await git.run(["add", "-A"], in: repo)
        _ = try await git.run(["commit", "-q", "-m", "base"], in: repo)
        base = try await git.run(["rev-parse", "HEAD"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await git.run(["worktree", "add", "-q", "-b", "thread", worktree.path, base], in: repo)
    }

    static func write(_ root: URL, _ name: String, _ content: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func build() async throws -> ReviewWorkspace.Built {
        let summary = try await DiffProvider(git: git).summary(worktree: worktree, base: base, limit: 500)
        return try await ReviewWorkspace.build(
            files: summary.files, base: base, worktree: worktree, repository: repo, destination: destination, git: git)
    }

    func status() async throws -> [String] {
        try await git.run(["status", "--porcelain"], in: destination).stdout.split(separator: "\n").map(String.init).sorted()
    }
}

@Suite(.processGate) struct ReviewWorkspaceTests {
    @Test func everyKindOfChangeShowsAsUncommittedWorkAtTheBase() async throws {
        let rig = try await WorkspaceRig()
        try WorkspaceRig.write(rig.worktree, "edit.txt", "two\n")
        try WorkspaceRig.write(rig.worktree, "new/deep/added.txt", "added\n")
        try FileManager.default.removeItem(at: rig.worktree.appendingPathComponent("drop.txt"))
        try FileManager.default.moveItem(
            at: rig.worktree.appendingPathComponent("move.txt"), to: rig.worktree.appendingPathComponent("renamed.txt"))
        let built = try await rig.build()

        #expect(built.skipped.isEmpty)
        let head = try await rig.git.run(["rev-parse", "HEAD"], in: rig.destination).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == rig.base)
        let status = try await rig.status()
        #expect(status.contains(" M edit.txt") && status.contains(" D drop.txt") && status.contains(" D move.txt"))
        #expect(status.contains("?? renamed.txt") && status.contains("?? new/"))
        #expect(!status.contains { $0.contains("keep.txt") })
        #expect(try String(contentsOf: rig.destination.appendingPathComponent("edit.txt"), encoding: .utf8) == "two\n")
    }

    @Test func committedAndUncommittedWorkBothShow() async throws {
        let rig = try await WorkspaceRig()
        try WorkspaceRig.write(rig.worktree, "edit.txt", "committed\n")
        _ = try await rig.git.run(["commit", "-q", "-am", "agent"], in: rig.worktree)
        try WorkspaceRig.write(rig.worktree, "keep.txt", "left over\n")
        _ = try await rig.build()
        let status = try await rig.status()
        #expect(status == [" M edit.txt", " M keep.txt"])
    }

    @Test func theWorktreeAndTheRepositoryAreLeftAsTheyWere() async throws {
        let rig = try await WorkspaceRig()
        try WorkspaceRig.write(rig.worktree, "edit.txt", "two\n")
        _ = try await rig.build()
        let remotes = try await rig.git.run(["remote"], in: rig.destination).stdout
        #expect(remotes.isEmpty, "nothing to push to")
        let worktrees = try await rig.git.run(["worktree", "list"], in: rig.repo).stdout.split(separator: "\n")
        #expect(worktrees.count == 2, "the workspace registers nothing in the repository")
        #expect(try String(contentsOf: rig.worktree.appendingPathComponent("edit.txt"), encoding: .utf8) == "two\n")
    }

    @Test func aLinkedFolderCannotLeadACopyOutsideTheWorkspace() async throws {
        let rig = try await WorkspaceRig()
        // The repository itself tracks a link to a folder outside; a file the thread puts under it must not be written there.
        try FileManager.default.createSymbolicLink(
            at: rig.repo.appendingPathComponent("link"), withDestinationURL: rig.outside)
        _ = try await rig.git.run(["add", "-A"], in: rig.repo)
        _ = try await rig.git.run(["commit", "-q", "-m", "link"], in: rig.repo)
        let base = try await rig.git.run(["rev-parse", "HEAD"], in: rig.repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let files = [FileChange(path: "link/escape.txt", status: .added, isBinary: false, isUntracked: true)]
        // In the thread's worktree (made before the link) `link` is a real folder, so the source is a plain file: only the
        // workspace's own `link`, which is the repository's, leads outside.
        try WorkspaceRig.write(rig.worktree, "link/escape.txt", "from the thread\n")
        try "secret\n".write(to: rig.outside.appendingPathComponent("escape.txt"), atomically: true, encoding: .utf8)
        let built = try await ReviewWorkspace.build(
            files: files, base: base, worktree: rig.worktree, repository: rig.repo, destination: rig.destination, git: rig.git)

        #expect(built.skipped == ["link/escape.txt"])
        let leftOutside = try FileManager.default.contentsOfDirectory(atPath: rig.outside.path)
        #expect(leftOutside == ["escape.txt"], "nothing new outside: \(leftOutside)")
        let kept = try String(contentsOf: rig.outside.appendingPathComponent("escape.txt"), encoding: .utf8)
        #expect(kept == "secret\n")
    }

    @Test func aFileTooLargeOrNotAPlainFileIsLeftOutAndNamed() async throws {
        let rig = try await WorkspaceRig()
        try WorkspaceRig.write(rig.worktree, "big.txt", String(repeating: "x", count: ReviewWorkspace.sizeLimit + 1))
        try FileManager.default.createSymbolicLink(
            at: rig.worktree.appendingPathComponent("pointer"), withDestinationURL: rig.outside)
        try WorkspaceRig.write(rig.worktree, "edit.txt", "two\n")
        let built = try await rig.build()
        #expect(Set(built.skipped) == ["big.txt", "pointer"])
        #expect(built.changed == 1)
    }

    @Test func aNewFileAtARenamedFilesOldPathIsNotErasedWhateverTheOrder() async throws {
        let rig = try await WorkspaceRig(files: ["a.txt": "old a\n"])
        try WorkspaceRig.write(rig.worktree, "a.txt", "new a\n")
        try WorkspaceRig.write(rig.worktree, "z.txt", "old a\n")
        let files = [
            FileChange(path: "a.txt", status: .added, isBinary: false, isUntracked: false),
            FileChange(path: "z.txt", oldPath: "a.txt", status: .renamed, isBinary: false, isUntracked: false),
        ]
        _ = try await ReviewWorkspace.build(
            files: files, base: rig.base, worktree: rig.worktree, repository: rig.repo, destination: rig.destination,
            git: rig.git)
        #expect(try String(contentsOf: rig.destination.appendingPathComponent("a.txt"), encoding: .utf8) == "new a\n")
        #expect(FileManager.default.fileExists(atPath: rig.destination.appendingPathComponent("z.txt").path))
    }

    @Test func aRenameWhoseNewVersionIsLeftOutIsNotShownAsADeletion() async throws {
        let rig = try await WorkspaceRig(files: ["big.txt": String(repeating: "x", count: ReviewWorkspace.sizeLimit + 1)])
        try FileManager.default.moveItem(
            at: rig.worktree.appendingPathComponent("big.txt"), to: rig.worktree.appendingPathComponent("big2.txt"))
        let files = [FileChange(path: "big2.txt", oldPath: "big.txt", status: .renamed, isBinary: false, isUntracked: false)]
        let built = try await ReviewWorkspace.build(
            files: files, base: rig.base, worktree: rig.worktree, repository: rig.repo, destination: rig.destination,
            git: rig.git)
        #expect(built.skipped == ["big2.txt"])
        #expect(try await rig.status().isEmpty, "the base's file is still there, unchanged")
    }

    @Test func aFileTheRepositoryIgnoresButTheThreadAddedStillShowsInSourceControl() async throws {
        let rig = try await WorkspaceRig(files: [".gitignore": "generated/\n", "keep.txt": "keep\n"])
        try WorkspaceRig.write(rig.worktree, "generated/café résultat.txt", "made\n")
        _ = try await rig.git.run(["add", "--force", "generated/café résultat.txt"], in: rig.worktree)
        _ = try await rig.git.run(["commit", "-q", "-m", "forced"], in: rig.worktree)
        let built = try await rig.build()
        #expect(built.changed == 1)
        let status = try await rig.status()
        #expect(status == [" A \"generated/caf\\303\\251 r\\303\\251sultat.txt\""], "shown as a new file: \(status)")
    }

    @Test func aRebuildReplacesWhatWasThere() async throws {
        let rig = try await WorkspaceRig()
        try WorkspaceRig.write(rig.worktree, "edit.txt", "two\n")
        _ = try await rig.build()
        try WorkspaceRig.write(rig.destination, "scribble.txt", "mine\n")
        try FileManager.default.removeItem(at: rig.worktree.appendingPathComponent("edit.txt"))
        _ = try await rig.git.run(["checkout", "--", "edit.txt"], in: rig.worktree)
        try WorkspaceRig.write(rig.worktree, "keep.txt", "three\n")
        _ = try await rig.build()
        #expect(try await rig.status() == [" M keep.txt"])
    }

    @Test func onlyAFolderNamedForItIsEverEmptied() async throws {
        let rig = try await WorkspaceRig()
        try WorkspaceRig.write(rig.outside, "precious.txt", "keep\n")
        await #expect(throws: EditorError.self) {
            _ = try await ReviewWorkspace.build(
                files: [], base: rig.base, worktree: rig.worktree, repository: rig.repo, destination: rig.outside, git: rig.git)
        }
        #expect(FileManager.default.fileExists(atPath: rig.outside.appendingPathComponent("precious.txt").path))
    }
}

@Suite(.processGate) struct ReviewWorkspaceThreadTests {
    @Test func aThreadsWorkspaceHoldsItsChangesAndGoesWithItsWorktree() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let manager = WorktreeManager(repoRoot: fx.repo, git: fx.git)
        let created = try await manager.create(threadID: id, base: "main")
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(
            .worktreeCreated,
            data: ["path": .string(created.path.path), "branch": .string(created.branch),
                "base_commit": .string(created.baseCommit)])
        await log.close()
        try "from the thread\n".write(to: created.path.appendingPathComponent("made.txt"), atomically: true, encoding: .utf8)

        let built = try await ReviewWorkspace.prepare(project: fx.project, threadID: id, git: fx.git)
        let expected = fx.project.threadDirectory(id).appendingPathComponent(ReviewWorkspace.folderName, isDirectory: true)
        #expect(built.path == expected)
        let status = try await fx.git.run(["status", "--porcelain"], in: built.path).stdout
        #expect(status == "?? made.txt\n")

        try await manager.remove(threadID: id, force: true)
        #expect(!FileManager.default.fileExists(atPath: built.path.path))
        #expect(FileManager.default.fileExists(atPath: fx.project.goalURL(id).path), "the thread's own files stay")
    }

    @Test func aThreadWithNoWorktreeIsRefused() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        await #expect(throws: EditorError.self) {
            _ = try await ReviewWorkspace.prepare(project: fx.project, threadID: id, git: fx.git)
        }
    }
}
