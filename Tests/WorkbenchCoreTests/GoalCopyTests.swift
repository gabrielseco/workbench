import Foundation
import Testing

@testable import WorkbenchCore

/// The approved goal, read-only, inside the thread's worktree, so an editor opened on it shows the goal beside the diff.
@Suite struct GoalCopyTests {
    private func copyURL(_ fx: RunnerFixture, _ id: String) -> URL {
        fx.project.worktreesDirectory.appendingPathComponent(id).appendingPathComponent(".workbench/goal.md")
    }

    @Test func aRunPutsAReadOnlyCopyOfTheGoalInTheWorktree() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))

        let copy = copyURL(fx, id)
        let goal = try String(contentsOf: fx.project.goalURL(id), encoding: .utf8)
        #expect(try String(contentsOf: copy, encoding: .utf8) == goal)
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect(mode == 0o444, "read-only, so an edit has to be deliberate")
    }

    @Test func theCopyIsNeverCommitted() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))

        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(FileManager.default.fileExists(atPath: copyURL(fx, id).path), "there is a copy to leave out")
        _ = try await fx.git.run(["add", "-A"], in: worktree)
        let staged = try await fx.git.run(["diff", "--cached", "--name-only"], in: worktree)
        #expect(!staged.stdout.contains("goal.md"), "git add -A must leave the copy out: \(staged.stdout)")
        let status = try await fx.git.run(["status", "--porcelain", "--untracked-files=all"], in: worktree)
        #expect(!status.stdout.contains(".workbench"), "the copy does not show as a change: \(status.stdout)")
    }

    @Test func aSendBackRestoresTheCopyAndLeavesTheApprovedGoalAlone() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))

        let goalBefore = try String(contentsOf: fx.project.goalURL(id), encoding: .utf8)
        let copy = copyURL(fx, id)
        // Someone edits the copy on purpose.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        try "edited in the worktree\n".write(to: copy, atomically: true, encoding: .utf8)

        let second = try await fx.runner(id).run(fx.options("stream-events=1", feedback: "Also add a farewell."))
        #expect(second.result == .succeeded)

        #expect(try String(contentsOf: copy, encoding: .utf8) == goalBefore, "the next turn puts the goal back")
        #expect(try String(contentsOf: fx.project.goalURL(id), encoding: .utf8) == goalBefore)
        // Still approved: the edit never reached the goal the approval covers.
        let state = ThreadStore(project: fx.project).state(of: id)
        let goal = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8)).goal
        #expect(state.approvedGoalHash == goal.contentHash)
    }

    @Test func aWorktreeWhereTheCopyWouldNotBeIgnoredGetsNone() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        // The project un-ignores .workbench in its own tracked .gitignore, so the copy would show as a change.
        try "!.workbench/\n".write(
            to: fx.repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", ".gitignore"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "unignore"], in: fx.repo)
        _ = try await fx.git.run(["config", "core.excludesFile", "/dev/null"], in: fx.repo)
        try "".write(
            to: fx.repo.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)

        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        let status = try await fx.git.run(["status", "--porcelain", "--untracked-files=all"], in: worktree)
        #expect(!status.stdout.contains("goal.md"), "nothing is written that git would then commit: \(status.stdout)")
    }

    @Test func aCopyFromAnEarlierTurnIsRemovedWhenTheIgnoreRulesChange() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        #expect(FileManager.default.fileExists(atPath: copyURL(fx, id).path))

        // Between turns the project un-ignores .workbench/ (in the worktree's own checkout), so a copy left behind would be staged.
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "!.workbench/\n".write(
            to: worktree.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["config", "core.excludesFile", "/dev/null"], in: fx.repo)
        try "".write(to: fx.repo.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)

        _ = try await fx.runner(id).run(fx.options("stream-events=1", feedback: "Again."))
        #expect(!FileManager.default.fileExists(atPath: copyURL(fx, id).path))
        _ = try await fx.git.run(["add", "-A"], in: worktree)
        let staged = try await fx.git.run(["diff", "--cached", "--name-only"], in: worktree)
        #expect(!staged.stdout.contains("goal.md"), "staged: \(staged.stdout)")
    }

    @Test func aSymlinkedWorkbenchFolderIsNeverFollowed() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let goalBefore = try String(contentsOf: fx.project.goalURL(id), encoding: .utf8)

        // `.workbench` in the worktree becomes a link to the thread's own folder, and the ignore rules stop covering it.
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        let folder = worktree.appendingPathComponent(".workbench")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copyURL(fx, id).path)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: fx.project.threadDirectory(id))
        _ = await WorktreeManager(repoRoot: fx.repo, git: fx.git).writeGoalCopy("replacement\n", for: id)

        #expect(try String(contentsOf: fx.project.goalURL(id), encoding: .utf8) == goalBefore, "the source goal is untouched")
    }

    @Test func aTrackedFileAtThePathIsLeftAlone() async throws {
        let fx = try await RunnerFixture()
        // The project's own tracked file, on the thread's base.
        let dir = fx.repo.appendingPathComponent(".workbench")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "the project's own\n".write(to: dir.appendingPathComponent("goal.md"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-f", ".workbench/goal.md"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "track it"], in: fx.repo)
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))

        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(try String(contentsOf: copyURL(fx, id), encoding: .utf8) == "the project's own\n")
        let status = try await fx.git.run(["status", "--porcelain"], in: worktree)
        #expect(!status.stdout.contains("goal.md"), "no deletion or edit of a tracked file: \(status.stdout)")
    }
}
