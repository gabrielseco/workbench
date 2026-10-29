import Foundation
import Testing

@testable import WorkbenchCore

/// A repo with one commit as the base, work on top of it, and a `code` on PATH that writes down what it was asked to open.
private struct DiffRig {
    let root: URL
    let bin: URL
    let scratch: URL
    let git: GitRunner
    var log: URL { bin.appendingPathComponent("calls.txt") }
    var environment: [String: String] { ["PATH": bin.path, "HOME": NSHomeDirectory()] }

    init() async throws {
        let dir = Scratch.url("editordiff").resolvingSymlinksInPath()
        root = dir.appendingPathComponent("repo")
        bin = dir.appendingPathComponent("bin")
        scratch = dir.appendingPathComponent("diff-base")
        for folder in [root, bin] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        git = try GitRunner.discover(
            extraEnvironment: [
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
            ], timeout: 30)
        _ = try await git.run(["init", "-q", "-b", "main"], in: root)
        try launcher("code")
    }

    func launcher(_ name: String) throws {
        let file = bin.appendingPathComponent(name)
        try "#!/bin/sh\necho \"$@\" >> '\(log.path)'\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func write(_ name: String, _ content: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func commit() async throws -> String {
        _ = try await git.run(["add", "-A"], in: root)
        _ = try await git.run(["commit", "-q", "-m", "c"], in: root)
        return try await git.run(["rev-parse", "HEAD"], in: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func calls() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func open(base: String, only: String? = nil, editor: String = "code") async throws -> EditorDiff.Opened {
        let summary = try await DiffProvider(git: git).summary(worktree: root, base: base, limit: 500)
        return try await EditorDiff.open(
            files: summary.files, only: only, base: base, worktree: root, scratch: scratch, git: git, editor: editor,
            environment: environment)
    }
}

@Suite struct EditorDiffTests {
    @Test func aChangedFileOpensAsItsBaseVersionBesideTheWorktreeFile() async throws {
        let rig = try await DiffRig()
        try rig.write("a.txt", "before\n")
        let base = try await rig.commit()
        try rig.write("a.txt", "after\n")
        _ = try await rig.commit()

        let done = try await rig.open(base: base)
        #expect(done.opened == ["a.txt"] && done.skipped.isEmpty && done.more == 0)
        let args = try #require(rig.calls().first).split(separator: " ").map(String.init)
        #expect(args.count == 3 && args[0] == "--diff" && args[2] == rig.root.appendingPathComponent("a.txt").path)
        #expect(try String(contentsOfFile: args[1], encoding: .utf8) == "before\n")
        #expect(args[1].hasPrefix(rig.scratch.path) && args[1].hasSuffix("/a.txt"), "the name is kept, for the language")
        #expect(try FileManager.default.attributesOfItem(atPath: args[1])[.posixPermissions] as? Int == 0o444)
    }

    @Test func anAddedFileHasAnEmptyBaseAndADeletedOneAnEmptyNewSide() async throws {
        let rig = try await DiffRig()
        try rig.write("gone.txt", "bye\n")
        let base = try await rig.commit()
        try FileManager.default.removeItem(at: rig.root.appendingPathComponent("gone.txt"))
        try rig.write("new.txt", "hello\n")
        _ = try await rig.commit()

        let done = try await rig.open(base: base)
        #expect(Set(done.opened) == ["gone.txt", "new.txt"])
        for call in rig.calls() {
            let args = call.split(separator: " ").map(String.init)
            if args[2].hasSuffix("/new.txt") { #expect(try String(contentsOfFile: args[1], encoding: .utf8).isEmpty) }
            if args[1].hasSuffix("/gone.txt") {
                #expect(try String(contentsOfFile: args[1], encoding: .utf8) == "bye\n")
                #expect(try String(contentsOfFile: args[2], encoding: .utf8).isEmpty)
            }
        }
    }

    @Test func aWholeReviewOpensAtMostTenFilesAndCountsTheRest() async throws {
        let rig = try await DiffRig()
        try rig.write("keep.txt", "x\n")
        let base = try await rig.commit()
        for n in 1...13 { try rig.write("f\(n).txt", "\(n)\n") }
        _ = try await rig.commit()

        let done = try await rig.open(base: base)
        #expect(done.opened.count == EditorDiff.fileLimit && done.more == 3)
        #expect(rig.calls().count == EditorDiff.fileLimit)
        // A file asked for by name is opened whatever its place in the list.
        let one = try await rig.open(base: base, only: "f13.txt")
        #expect(one.opened == ["f13.txt"] && one.more == 0)
    }

    @Test func aBinaryFileIsLeftOutAndNamed() async throws {
        let rig = try await DiffRig()
        try rig.write("keep.txt", "x\n")
        let base = try await rig.commit()
        try Data([0, 1, 2, 0, 255]).write(to: rig.root.appendingPathComponent("blob.bin"))
        try rig.write("text.txt", "t\n")
        _ = try await rig.commit()

        let done = try await rig.open(base: base)
        #expect(done.opened == ["text.txt"] && done.skipped == ["blob.bin"])
    }

    @Test func anEditorWithoutADiffViewIsRefusedBeforeAnythingIsWritten() async throws {
        let rig = try await DiffRig()
        try rig.launcher("subl")
        try rig.write("a.txt", "1\n")
        let base = try await rig.commit()
        try rig.write("a.txt", "2\n")
        _ = try await rig.commit()

        await #expect(throws: EditorError.noDiffMode(editor: "subl")) { try await rig.open(base: base, editor: "subl") }
        #expect(!FileManager.default.fileExists(atPath: rig.scratch.path) && rig.calls().isEmpty)
    }

    @Test func aLauncherThatIsNotOnPathIsNotFound() async throws {
        let rig = try await DiffRig()
        try FileManager.default.removeItem(at: rig.bin.appendingPathComponent("code"))
        await #expect(throws: EditorError.self) {
            try EditorDiff.command(for: "code", old: rig.root, new: rig.root, searchPath: rig.bin.path)
        }
    }

    @Test func aBaseThatIsNotACommitIdIsRefused() async throws {
        let rig = try await DiffRig()
        await #expect(throws: EditorError.self) {
            _ = try await EditorDiff.open(
                files: [], only: nil, base: "--output=x", worktree: rig.root, scratch: rig.scratch, git: rig.git,
                editor: "code", environment: rig.environment)
        }
    }

    @Test func aPathThatClimbsOutOfTheWorktreeIsLeftOut() async throws {
        let rig = try await DiffRig()
        try rig.write("keep.txt", "x\n")
        let base = try await rig.commit()
        let escaping = FileChange(
            path: "../outside.txt", status: .modified, additions: 1, deletions: 0, isBinary: false, isUntracked: false)
        let done = try await EditorDiff.open(
            files: [escaping], only: nil, base: base, worktree: rig.root, scratch: rig.scratch, git: rig.git, editor: "code",
            environment: rig.environment)
        #expect(done.opened.isEmpty && done.skipped == ["../outside.txt"] && rig.calls().isEmpty)
    }

    @Test func aLaterCallReplacesWhatAnEarlierOneLeft() async throws {
        let rig = try await DiffRig()
        try rig.write("a.txt", "1\n")
        let base = try await rig.commit()
        try rig.write("a.txt", "2\n")
        _ = try await rig.commit()
        _ = try await rig.open(base: base)
        let stale = rig.scratch.appendingPathComponent("stale.txt")
        try "old".write(to: stale, atomically: true, encoding: .utf8)
        _ = try await rig.open(base: base)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func aFolderReplacedByALinkOutOfTheWorktreeIsLeftOut() async throws {
        let rig = try await DiffRig()
        try rig.write("dir/a.txt", "inside\n")
        let base = try await rig.commit()
        let outside = rig.root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret\n".write(to: outside.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: rig.root.appendingPathComponent("dir"))
        try FileManager.default.createSymbolicLink(at: rig.root.appendingPathComponent("dir"), withDestinationURL: outside)

        let done = try await rig.open(base: base)
        #expect(done.opened.isEmpty && rig.calls().isEmpty, "the outside file is never handed to the editor")
        #expect(done.skipped == ["dir/a.txt"])
    }

    @Test func aFileOverTheSizeLimitOnEitherSideIsLeftOut() async throws {
        let rig = try await DiffRig()
        let big = String(repeating: "x", count: EditorDiff.sizeLimit + 1)
        try rig.write("old-big.txt", big)
        let base = try await rig.commit()
        try rig.write("old-big.txt", "small\n")
        try rig.write("new-big.txt", big)
        _ = try await rig.commit()

        let done = try await rig.open(base: base)
        #expect(done.opened.isEmpty && Set(done.skipped) == ["old-big.txt", "new-big.txt"] && rig.calls().isEmpty)
    }
}
