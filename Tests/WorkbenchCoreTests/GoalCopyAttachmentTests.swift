import Foundation
import Testing

@testable import WorkbenchCore

/// The goal's screenshots, shown to a coding turn: read-only copies in the worktree, beside the goal copy, never committed.
@Suite(.processGate) struct GoalCopyAttachmentTests {
    private func keep(_ fx: RunnerFixture, _ id: String, _ files: [String: String]) throws {
        let folder = fx.project.threadDirectory(id).appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
    }

    private func copies(_ fx: RunnerFixture, _ id: String) -> URL {
        fx.project.worktreesDirectory.appendingPathComponent(id).appendingPathComponent(WorktreeManager.attachmentCopyFolder)
    }

    private func prompt(_ fx: RunnerFixture, _ id: String) throws -> String {
        try String(contentsOf: fx.project.promptURL(id, turn: 1), encoding: .utf8)
    }

    @Test func aRunPutsReadOnlyCopiesInTheWorktreeAndTheFirstPromptNamesThemInOrder() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try keep(fx, id, ["2.jpg": "second", "1.png": "first", "10.png": "tenth"])
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))

        let folder = copies(fx, id)
        #expect(try String(contentsOf: folder.appendingPathComponent("1.png"), encoding: .utf8) == "first")
        #expect(try String(contentsOf: folder.appendingPathComponent("10.png"), encoding: .utf8) == "tenth")
        let first = folder.appendingPathComponent("1.png")
        #expect(try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int == 0o444)

        let text = try prompt(fx, id)
        let base = fx.project.worktreesDirectory.appendingPathComponent(id).path + "/" + WorktreeManager.attachmentCopyFolder
        let at = ["1.png", "2.jpg", "10.png"].compactMap { text.range(of: "\(base)/\($0)")?.lowerBound }
        #expect(at.count == 3 && at == at.sorted(), "all three named, in number order, not name order: \(text)")
    }

    @Test func theCopiesAreNeverCommittedOrShownAsChanges() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try keep(fx, id, ["1.png": "first"])
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))

        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(FileManager.default.fileExists(atPath: copies(fx, id).appendingPathComponent("1.png").path))
        _ = try await fx.git.run(["add", "-A"], in: worktree)
        let staged = try await fx.git.run(["diff", "--cached", "--name-only"], in: worktree)
        #expect(!staged.stdout.contains("attachments"), "git add -A leaves them out: \(staged.stdout)")
        let status = try await fx.git.run(["status", "--porcelain", "--untracked-files=all"], in: worktree)
        #expect(!status.stdout.contains(".workbench"), "\(status.stdout)")
    }

    @Test func aGoalWithNoScreenshotsHasNoScreenshotsInItsPromptAndNoFolder() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        #expect(!(try prompt(fx, id)).contains(WorktreeManager.attachmentCopyFolder))
        #expect(!FileManager.default.fileExists(atPath: copies(fx, id).path))
    }

    @Test func aNextTurnReplacesWhatTheLastLeftAndLeavesOtherFilesAlone() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try keep(fx, id, ["1.png": "first", "2.jpg": "second"])
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let folder = copies(fx, id)
        try "mine".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        try FileManager.default.removeItem(at: fx.project.threadDirectory(id).appendingPathComponent("attachments/2.jpg"))
        try Data("changed".utf8).write(to: fx.project.threadDirectory(id).appendingPathComponent("attachments/1.png"))
        let second = try await fx.runner(id).run(fx.options("stream-events=1", feedback: "Again."))
        #expect(second.result == .succeeded)

        #expect(try String(contentsOf: folder.appendingPathComponent("1.png"), encoding: .utf8) == "changed")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("2.jpg").path), "the removed one is gone")
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.txt"), encoding: .utf8) == "mine")
    }

    @Test func aTrackedFileInTheFolderIsLeftAloneAndNothingIsClaimedInThePrompt() async throws {
        let fx = try await RunnerFixture()
        let dir = fx.repo.appendingPathComponent(WorktreeManager.attachmentCopyFolder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "the project's own".write(to: dir.appendingPathComponent("1.png"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-f", WorktreeManager.attachmentCopyFolder], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "track it"], in: fx.repo)
        let id = try await fx.approvedThread()
        try keep(fx, id, ["1.png": "attached"])
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))

        #expect(try String(contentsOf: copies(fx, id).appendingPathComponent("1.png"), encoding: .utf8) == "the project's own")
        #expect(!(try prompt(fx, id)).contains("## Screenshots"))
    }

    @Test func aNameTheProjectsIgnoreRulesLetGitSeeIsNeverCopiedAndAnEarlierCopyIsRemoved() async throws {
        let fx = try await RunnerFixture()
        // The project un-ignores one screenshot name (and the folders above it), so `git add -A` would stage a copy of it.
        let rules = ["!.workbench/", "!.workbench/goal-copy/", ".workbench/goal-copy/attachments/*",
            "!.workbench/goal-copy/attachments/2.jpg", ""].joined(separator: "\n")
        try rules.write(to: fx.repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", ".gitignore"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "ignore rules"], in: fx.repo)
        let id = try await fx.approvedThread()
        try keep(fx, id, ["1.png": "first", "2.jpg": "second"])
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))

        let folder = copies(fx, id)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("1.png").path), "an ignored name is copied")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("2.jpg").path), "a visible one is not")
        let text = try prompt(fx, id)
        #expect(text.contains("/1.png") && !text.contains("/2.jpg"), "the prompt names only what was written")
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        _ = try await fx.git.run(["add", "-A"], in: worktree)
        let staged = try await fx.git.run(["diff", "--cached", "--name-only"], in: worktree)
        #expect(!staged.stdout.contains("attachments"), "nothing of the screenshots is staged: \(staged.stdout)")
    }

    @Test func cleanupTouchesOnlyNamesTheFeatureWritesNotLookAlikes() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try keep(fx, id, ["1.png": "first"])
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let folder = copies(fx, id)
        for name in ["01.png", "-1.png", "1.png.bak", "a.png"] {
            try "mine".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let second = try await fx.runner(id).run(fx.options("stream-events=1", feedback: "Again."))
        #expect(second.result == .succeeded)
        for name in ["01.png", "-1.png", "1.png.bak", "a.png"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was left alone")
        }
    }

    @Test func aCopyThatWasMadeAHardLinkToAnotherFileNeverChangesThatFilesPermissions() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try keep(fx, id, ["1.png": "first", "2.jpg": "second"])
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        let folder = copies(fx, id)
        // Two other files of the project, each linked in under a screenshot's name.
        let scripts = ["run.sh", "other.sh"].map { worktree.appendingPathComponent($0) }
        for (script, name) in zip(scripts, ["1.png", "2.jpg"]) {
            try "#!/bin/sh\necho kept\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            try FileManager.default.linkItem(at: script, to: folder.appendingPathComponent(name))
        }
        // The next turn replaces 1.png with new content and removes 2.jpg (it is gone from the thread).
        let attachments = fx.project.threadDirectory(id).appendingPathComponent("attachments")
        try Data("changed".utf8).write(to: attachments.appendingPathComponent("1.png"))
        try FileManager.default.removeItem(at: attachments.appendingPathComponent("2.jpg"))
        let second = try await fx.runner(id).run(fx.options("stream-events=1", feedback: "Again."))
        #expect(second.result == .succeeded)

        #expect(try String(contentsOf: folder.appendingPathComponent("1.png"), encoding: .utf8) == "changed")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("2.jpg").path))
        for script in scripts {
            let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
            #expect(mode == 0o755, "\(script.lastPathComponent) keeps its permissions")
            #expect(try String(contentsOf: script, encoding: .utf8) == "#!/bin/sh\necho kept\n", "and its content")
        }
    }

    @Test func onlyFilesWithTheNamesTheDraftWritesAreTakenAsScreenshots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stored-\(UUID().uuidString)")
        let folder = dir.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["1.png", "2.jpg", "3.gif", "4.webp", "01.png", "a.png", "5.svg", "6.png.txt", "7"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("8.png"), withDestinationURL: folder.appendingPathComponent("1.png"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("9.png"), withIntermediateDirectories: true)
        #expect(GoalAttachments.stored(in: dir).map(\.lastPathComponent) == ["1.png", "2.jpg", "3.gif", "4.webp"])
        #expect(GoalAttachments.stored(in: dir.appendingPathComponent("nothing")).isEmpty)
    }

    @Test func theScreenshotSectionIsInThePromptOnlyWithScreenshotsAndKeepsTheirOrder() throws {
        let text = """
            ---
            id: g-1
            title: T
            status: draft
            base: main
            budget_usd: 1
            turn_timeout_min: 5
            ---

            ## Request

            Do it.

            ## Criteria

            - [c1] It is done.
              - proof: a test

            ## Out of scope

            - Nothing else.
            """
        let goal = try GoalFile.parse(text).goal
        let none = PromptBuilder.firstPrompt(goal: goal, checkCommand: nil)
        let some = PromptBuilder.firstPrompt(goal: goal, checkCommand: nil, screenshots: ["2.jpg", "1.png"])
        #expect(none != some && !none.contains(WorktreeManager.attachmentCopyFolder))
        let first = some.range(of: "/2.jpg")
        let second = some.range(of: "/1.png")
        #expect(first != nil && second != nil && first!.lowerBound < second!.lowerBound, "the order given, not sorted")
        let tree = URL(fileURLWithPath: "/p/.workbench/worktrees/t")
        let absolute = PromptBuilder.firstPrompt(goal: goal, checkCommand: nil, screenshots: ["1.png"], worktree: tree)
        #expect(absolute.contains("`/p/.workbench/worktrees/t/\(WorktreeManager.attachmentCopyFolder)/1.png`"))
    }
}
