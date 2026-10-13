import Darwin
import Foundation
import Testing

@testable import WorkbenchCore

private func testGit() throws -> GitRunner {
    try GitRunner.discover(
        extraEnvironment: [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
        ], timeout: 30)
}

private struct DiffRepo {
    let root: URL
    let git: GitRunner
    var provider: DiffProvider { DiffProvider(git: git) }

    init() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir.resolvingSymlinksInPath()
        git = try testGit()
        try await run("init", "-q", "-b", "main")
        try write("keep.txt", "one\ntwo\nthree\n")
        try write("gone.txt", "bye\n")
        try write("old-name.txt", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try await run("add", "-A")
        try await run("commit", "-q", "-m", "base")
    }

    @discardableResult
    func run(_ args: String...) async throws -> GitResult {
        let result = try await git.run(args, in: root)
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
        return result
    }

    func write(_ name: String, _ content: String) throws {
        try Data(content.utf8).write(to: root.appendingPathComponent(name))
    }

    func base() async throws -> String {
        try await run("rev-parse", "HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status() async throws -> Set<String> {
        let out = try await run("status", "--porcelain", "-z", "--untracked-files=all").stdout
        return Set(out.split(separator: "\0").map { String($0.dropFirst(3)) })
    }
}

@Suite struct DiffTests {
    @Test func showsTheSameFilesAsGitStatus() async throws {
        let repo = try await DiffRepo()
        let base = try await repo.base()
        try repo.write("keep.txt", "one\ntwo\nthree\nfour\n")
        try repo.write("new.txt", "a\nb\n")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.txt"))

        let summary = try await repo.provider.summary(worktree: repo.root, base: base)
        let byPath = Dictionary(uniqueKeysWithValues: summary.files.map { ($0.path, $0) })

        #expect(Set(byPath.keys) == (try await repo.status()))
        #expect(byPath["keep.txt"]?.status == .modified)
        #expect(byPath["keep.txt"]?.additions == 1)
        #expect(byPath["keep.txt"]?.deletions == 0)
        #expect(byPath["gone.txt"]?.status == .deleted)
        #expect(byPath["gone.txt"]?.deletions == 1)
        #expect(byPath["new.txt"]?.status == .added)
        #expect(byPath["new.txt"]?.isUntracked == true)
        #expect(byPath["new.txt"]?.additions == 2)
        #expect(summary.totalFiles == 3)
        #expect(!summary.truncated)
    }

    @Test func committedWorkStillShowsAgainstBase() async throws {
        let repo = try await DiffRepo()
        let base = try await repo.base()
        try repo.write("keep.txt", "changed\n")
        try await repo.run("commit", "-qam", "turn work")
        try repo.write("extra.txt", "x\n")

        let summary = try await repo.provider.summary(worktree: repo.root, base: base)
        #expect(Set(summary.files.map(\.path)) == ["keep.txt", "extra.txt"])
    }

    @Test func noChangesIsEmpty() async throws {
        let repo = try await DiffRepo()
        let summary = try await repo.provider.summary(worktree: repo.root, base: try await repo.base())
        #expect(summary.files.isEmpty)
    }

    @Test func renameIsOneEntryWithBothPaths() async throws {
        let repo = try await DiffRepo()
        let base = try await repo.base()
        try await repo.run("mv", "old-name.txt", "new-name.txt")

        let summary = try await repo.provider.summary(worktree: repo.root, base: base)
        #expect(summary.files.count == 1)
        #expect(summary.files[0].status == .renamed)
        #expect(summary.files[0].oldPath == "old-name.txt")
        #expect(summary.files[0].path == "new-name.txt")
    }

    @Test func binaryFilesHaveNoCountsAndNoPatch() async throws {
        let repo = try await DiffRepo()
        let base = try await repo.base()
        try Data([0, 1, 2, 0, 255, 0]).write(to: repo.root.appendingPathComponent("blob.bin"))

        let summary = try await repo.provider.summary(worktree: repo.root, base: base)
        let file = try #require(summary.files.first)
        #expect(file.isBinary)
        #expect(file.additions == nil)
        #expect(try await repo.provider.patch(for: file, worktree: repo.root, base: base) == .binary)
    }

    @Test func trackedBinaryChangeIsBinary() async throws {
        let repo = try await DiffRepo()
        try Data([0, 1, 2]).write(to: repo.root.appendingPathComponent("b.bin"))
        try await repo.run("add", "-A")
        try await repo.run("commit", "-qm", "bin")
        let base = try await repo.base()
        try Data([0, 9, 9, 9]).write(to: repo.root.appendingPathComponent("b.bin"))

        let summary = try await repo.provider.summary(worktree: repo.root, base: base)
        #expect(summary.files.first?.isBinary == true)
    }

    @Test func ignoredSymlinkToFIFOHasNoCounts() async throws {
        let repo = try await DiffRepo()
        try repo.write(".gitignore", "ignored-link\npipe\n")
        try await repo.run("add", ".gitignore")
        try await repo.run("commit", "-qm", "ignore pipe")
        let base = try await repo.base()
        let pipe = repo.root.appendingPathComponent("pipe")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(
            at: repo.root.appendingPathComponent("ignored-link"), withDestinationURL: pipe)
        let fd = Darwin.open(pipe.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(fd >= 0)
        let marker: [UInt8] = [0x78, 0x0A]
        #expect(marker.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == marker.count)
        let finished = DispatchSemaphore(value: 0)
        // Let a reader of the old implementation reach EOF instead of hanging the test indefinitely.
        DispatchQueue.global().async {
            _ = finished.wait(timeout: .now() + 30)
            Darwin.close(fd)
        }
        defer { finished.signal() }

        let summary = try await repo.provider.summary(worktree: repo.root, base: base, includeIgnored: true)
        let link = try #require(summary.files.first { $0.path == "ignored-link" })
        #expect(link.isBinary)
        #expect(link.additions == nil)
        #expect(link.deletions == nil)
        #expect(try await repo.provider.patch(for: link, worktree: repo.root, base: base) == .binary)
    }

    @Test func untrackedLineCountingStopsAtByteLimit() async throws {
        let repo = try await DiffRepo()
        let base = try await repo.base()
        let limit = DiffProvider.untrackedCountLimit
        try Data(repeating: 0x0A, count: limit).write(to: repo.root.appendingPathComponent("at-limit.txt"))
        try Data(repeating: 0x0A, count: limit + 1).write(to: repo.root.appendingPathComponent("over-limit.txt"))

        let summary = try await repo.provider.summary(worktree: repo.root, base: base)
        let exact = try #require(summary.files.first { $0.path == "at-limit.txt" })
        let large = try #require(summary.files.first { $0.path == "over-limit.txt" })
        #expect(exact.additions == limit)
        #expect(!exact.isBinary)
        #expect(large.additions == nil)
        #expect(large.deletions == nil)
        #expect(!large.isBinary)
        guard case .tooLarge(let bytes) = try await repo.provider.patch(for: large, worktree: repo.root, base: base)
        else { Issue.record("expected tooLarge for over-limit text"); return }
        #expect(bytes > DiffProvider.patchLimit)
    }

    @Test func patchHasHunksForTrackedAndUntrackedFiles() async throws {
        let repo = try await DiffRepo()
        let base = try await repo.base()
        try repo.write("keep.txt", "one\nTWO\nthree\n")
        try repo.write("new.txt", "hello\n")

        let summary = try await repo.provider.summary(worktree: repo.root, base: base)
        for file in summary.files {
            guard case .text(let patch) = try await repo.provider.patch(for: file, worktree: repo.root, base: base)
            else { Issue.record("no text patch for \(file.path)"); continue }
            #expect(patch.contains("@@"))
        }
        let keep = try #require(summary.files.first { $0.path == "keep.txt" })
        guard case .text(let patch) = try await repo.provider.patch(for: keep, worktree: repo.root, base: base)
        else { return }
        #expect(patch.contains("-two"))
        #expect(patch.contains("+TWO"))
    }

    @Test func hugePatchFallsBackToTooLarge() async throws {
        let repo = try await DiffRepo()
        let base = try await repo.base()
        let big = String(repeating: "0123456789abcdef\n", count: 40_000)
        try repo.write("big.txt", big)

        let summary = try await repo.provider.summary(worktree: repo.root, base: base)
        let file = try #require(summary.files.first)
        #expect(file.additions == 40_000)
        guard case .tooLarge(let bytes) = try await repo.provider.patch(for: file, worktree: repo.root, base: base)
        else { Issue.record("expected tooLarge"); return }
        #expect(bytes > DiffProvider.patchLimit)
    }

    @Test func manyFilesAreCutAndFlagged() async throws {
        let repo = try await DiffRepo()
        let base = try await repo.base()
        for i in 0..<(DiffProvider.fileLimit + 20) { try repo.write("f\(i).txt", "x\n") }

        let summary = try await repo.provider.summary(worktree: repo.root, base: base)
        #expect(summary.files.count == DiffProvider.fileLimit)
        #expect(summary.totalFiles == DiffProvider.fileLimit + 20)
        #expect(summary.truncated)
    }

    @Test func missingWorktreeIsAnError() async throws {
        let repo = try await DiffRepo()
        let gone = repo.root.appendingPathComponent("nope")
        await #expect(throws: DiffError.worktreeNotFound(gone.path)) {
            _ = try await repo.provider.summary(worktree: gone, base: "HEAD")
        }
    }

    @Test func parsesNumstatAndNameStatus() {
        let numstat = "3\t1\ta b.txt\0-\t-\tpic.png\00\t0\t\0old.txt\0new.txt\0"
        let parsed = DiffProvider.parseNumstat(numstat)
        #expect(parsed.map(\.path) == ["a b.txt", "pic.png", "new.txt"])
        #expect(parsed[1].isBinary)
        #expect(parsed[2].oldPath == "old.txt")

        let statuses = DiffProvider.parseNameStatus("M\0a b.txt\0A\0pic.png\0R100\0old.txt\0new.txt\0D\0x\0")
        #expect(statuses == ["a b.txt": .modified, "pic.png": .added, "new.txt": .renamed, "x": .deleted])
    }
}
