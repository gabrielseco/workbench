import Foundation
import Testing

@testable import WorkbenchCore

/// A repository with one commit holding ordinary files and the things a snapshot must leave out, then changes the commit does not
/// have (an edit, an untracked file, an ignored one).
private struct SnapshotRepo {
    let root: URL
    let git: GitRunner
    var commit = ""

    init(extra: [String: String] = [:], bigFile: Bool = true, git: GitRunner? = nil) async throws {
        self.git = try git ?? isolatedGit()
        root = Scratch.url("snapshot-repo").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await self.git.run(["init", "-q", "-b", "main"], in: root)
        var files = [
            "src/app.swift": "let committed = 1\n", "docs/README.md": "# docs\n", "dir with space/é.txt": "unicode\n",
            "-dash.txt": "dash\n", ".gitignore": ".env*\n",
        ]
        files.merge(extra) { _, new in new }
        if bigFile { files["big.bin"] = String(repeating: "x", count: 700 << 10) }
        for (path, text) in files { try write(path, text) }
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("src/rel").path, withDestinationPath: "app.swift")
        _ = try await self.git.run(["add", "-A", "--", "."], in: root)
        // A submodule entry: a commit id in the tree where a directory would be.
        _ = try await self.git.run(
            ["update-index", "--add", "--cacheinfo", "160000,\(String(repeating: "a", count: 40)),vendor/lib"], in: root)
        _ = try await self.git.run(["commit", "-q", "-m", "one"], in: root)
        commit = try await self.git.run(["rev-parse", "HEAD"], in: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // What the commit does not have.
        try write("src/app.swift", "let edited = 2\n")
        try write("notes.txt", "untracked\n")
        try write(".env.local", "SECRET=1\n")
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func state() async throws -> [String] {
        var out: [String] = []
        let questions = [
            ["status", "--porcelain", "--ignored"], ["branch", "--list", "-a"], ["worktree", "list"], ["stash", "list"],
        ]
        for args in questions {
            out.append(try await git.run(args, in: root).stdout)
        }
        out.append((try? Data(contentsOf: root.appendingPathComponent(".git/index")).base64EncodedString()) ?? "")
        return out
    }

    func folder() -> URL { Self.folder() }
    static func folder() -> URL { Scratch.url("snapshot-work").resolvingSymlinksInPath() }

    /// The regular files in the copy, as paths relative to it.
    func list(_ folder: URL) -> Set<String> {
        let base = folder.appendingPathComponent(RepoSnapshot.folderName).resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) else { return [] }
        var found: Set<String> = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            found.insert(String(url.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1)))
        }
        return found
    }
}

@Suite(.processGate) struct RepoSnapshotTests {
    @Test func theTrackedRegularFilesAtTheCommitAreCopiedAndNothingElse() async throws {
        let repo = try await SnapshotRepo()
        let work = repo.folder()
        let snapshot = try #require(await RepoSnapshotWriter.write(base: "main", into: work, repo: repo.root, git: repo.git))

        let found = repo.list(work)
        #expect(found == ["src/app.swift", "docs/README.md", "dir with space/é.txt", "-dash.txt", ".gitignore"])
        let text = try String(contentsOf: work.appendingPathComponent("repo/src/app.swift"), encoding: .utf8)
        #expect(text == "let committed = 1\n", "the commit's content, not the edit in the working tree")
        let fm = FileManager.default
        for absent in ["notes.txt", ".env.local", "big.bin", "link", "src/rel", "vendor/lib", ".git"] {
            #expect(!fm.fileExists(atPath: work.appendingPathComponent("repo/\(absent)").path), "\(absent) is not in the copy")
        }
        #expect(snapshot.commit == repo.commit && snapshot.files == 5)
        #expect(snapshot.left == 4, "the large file, both links and the submodule")
    }

    @Test func theRepositoryIsLeftExactlyAsItWas() async throws {
        let repo = try await SnapshotRepo()
        let before = try await repo.state()
        _ = try #require(await RepoSnapshotWriter.write(base: "main", into: repo.folder(), repo: repo.root, git: repo.git))
        #expect(try await repo.state() == before, "status, branches, worktrees, stash and the index are untouched")
        let marker = try await repo.git.run(["status", "--porcelain"], in: repo.root).stdout
        #expect(marker.contains("src/app.swift") && marker.contains("notes.txt"), "the person's own changes are still there")
    }

    @Test func aBaseThatIsNotACommitOrAnEmptyTreeGivesNoCopy() async throws {
        let repo = try await SnapshotRepo()
        for base in ["no-such-branch", "--output=/tmp/x", "", "main:src"] {
            let work = repo.folder()
            #expect(await RepoSnapshotWriter.write(base: base, into: work, repo: repo.root, git: repo.git) == nil, "\(base)")
            #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("repo").path))
        }
    }

    @Test func theLimitsCutTheCopyAndCountWhatWasLeft() async throws {
        let repo = try await SnapshotRepo(bigFile: false)
        let limits = RepoSnapshotWriter.Limits(fileBytes: 12, totalBytes: 30, files: 3)
        let snapshot = try #require(
            await RepoSnapshotWriter.write(base: "main", into: repo.folder(), repo: repo.root, git: repo.git, limits: limits))
        #expect(snapshot.files <= 3 && snapshot.bytes <= 30)
        #expect(snapshot.files + snapshot.left == 8, "every tracked entry is either in the copy or counted as left out")
    }

    @Test func manyFilesAreCopiedInSeveralCommands() async throws {
        let files = Dictionary(uniqueKeysWithValues: (0..<450).map { ("bulk/d\($0 % 7)/file-\($0).txt", "n\($0)\n") })
        let repo = try await SnapshotRepo(extra: files, bigFile: false)
        let work = repo.folder()
        let snapshot = try #require(await RepoSnapshotWriter.write(base: "main", into: work, repo: repo.root, git: repo.git))
        #expect(snapshot.files == 455)
        #expect(repo.list(work).filter { $0.hasPrefix("bulk/") }.count == 450)
    }

    @Test func aFilterTheCheckoutWouldRunIsNotRun() async throws {
        let folder = Scratch.url("snapshot-filter").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("ran")
        let config = folder.appendingPathComponent("gitconfig")
        // Quoted as a whole: a bare `;` would start a comment in the config.
        let filter = "[filter \"evil\"]\n\tsmudge = \"sh -c 'cat; touch \(marker.path)'\"\n"
        try filter.write(to: config, atomically: true, encoding: .utf8)
        let base = try isolatedGit()
        var env = base.environment
        env["GIT_CONFIG_GLOBAL"] = config.path
        let configured = GitRunner(executable: base.executable, environment: env, timeout: base.timeout)
        let repo = try await SnapshotRepo(extra: [".gitattributes": "*.txt filter=evil\n"], bigFile: false, git: base)
        let work = repo.folder()
        _ = try #require(await RepoSnapshotWriter.write(base: "main", into: work, repo: repo.root, git: configured))
        #expect(repo.list(work).contains("docs/README.md") || repo.list(work).contains("-dash.txt"))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the person's own git config never reaches the copy")
    }

    @Test func aFilterInTheRepositoryOwnConfigIsNotRunEither() async throws {
        let folder = Scratch.url("snapshot-local-filter").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("ran")
        let repo = try await SnapshotRepo(extra: [".gitattributes": "*.txt filter=evil\n"], bigFile: false)
        // The person's own `.git/config`, which turning the global and system config off does not reach, and `info/attributes`.
        let smudge = "sh -c 'cat; touch \(marker.path)'"
        _ = try await repo.git.run(["config", "--local", "filter.evil.smudge", smudge], in: repo.root)
        _ = try await repo.git.run(["config", "--local", "filter.evil.process", "touch \(marker.path)"], in: repo.root)
        try "*.md filter=evil\n".write(
            to: repo.root.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        let work = repo.folder()
        _ = try #require(await RepoSnapshotWriter.write(base: "main", into: work, repo: repo.root, git: repo.git))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "no filter of the repository's own config ran")
        let found = repo.list(work)
        #expect(found.contains("-dash.txt") && found.contains("docs/README.md"))
        let text = try String(contentsOf: work.appendingPathComponent("repo/-dash.txt"), encoding: .utf8)
        #expect(text == "dash\n", "the committed bytes, as stored")
    }

    @Test func aPartialCloneIsNeverAskedToFetchItsMissingObjects() async throws {
        let source = try await SnapshotRepo(bigFile: false)
        _ = try await source.git.run(["config", "uploadpack.allowFilter", "true"], in: source.root)
        _ = try await source.git.run(["config", "uploadpack.allowAnySHA1InWant", "true"], in: source.root)
        // A blobless clone: the commits and trees are here, the files' contents are promised by `origin`, which is reachable, so a
        // fetch would work and would leave a pack behind.
        let clone = Scratch.url("snapshot-partial").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cloned = try await source.git.run(
            ["-c", "protocol.file.allow=always", "clone", "-q", "--no-checkout", "--filter=blob:none",
                "file://\(source.root.path)", clone.path], in: clone.deletingLastPathComponent())
        try #require(cloned.succeeded, "the partial clone: \(cloned.stderr)")
        let packFolder = clone.appendingPathComponent(".git/objects/pack").path
        let packs = { (try? FileManager.default.contentsOfDirectory(atPath: packFolder)) ?? [] }
        let before = packs().sorted()

        let work = SnapshotRepo.folder()
        let snapshot = await RepoSnapshotWriter.write(base: "main", into: work, repo: clone, git: source.git)
        #expect(snapshot == nil, "sizes and contents are not here, so there is no copy")
        #expect(packs().sorted() == before, "and nothing was fetched into the person's repository")
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("repo").path))
    }

    @Test func whatTheCheckoutMadeIsCheckedAndATooLargeFolderIsNoCopy() throws {
        let folder = Scratch.url("snapshot-keep").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("d"), withIntermediateDirectories: true)
        let fm = FileManager.default
        let small = folder.appendingPathComponent("d/small"), big = folder.appendingPathComponent("big")
        try String(repeating: "a", count: 10).write(to: small, atomically: true, encoding: .utf8)
        try String(repeating: "b", count: 50).write(to: big, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        #expect(RepoSnapshotWriter.keepWithinLimits(folder, .init(fileBytes: 20, totalBytes: 100, files: 10)))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("d/small").path))
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent("big").path), "over the per-file limit")
        let link = folder.appendingPathComponent("link").path
        #expect((try? fm.destinationOfSymbolicLink(atPath: link)) == nil, "the link is gone")
        #expect(!RepoSnapshotWriter.keepWithinLimits(folder, .init(fileBytes: 20, totalBytes: 5, files: 10)), "past the total")
    }

    @Test func onlyOrdinaryRelativePathsAreChosen() {
        for good in ["a", "src/app.swift", "dir with space/é.txt", "-dash.txt", ".github/workflows/ci.yml", "a/b.c/d"] {
            #expect(RepoSnapshotWriter.isPlain(good), "\(good)")
        }
        let bad = ["", "/etc/passwd", "../x", "a/../b", "a/./b", "a//b", ".git/config", "a/.GIT/x", "a\nb", "a\u{7f}b"]
        for bad in bad + [String(repeating: "x", count: 301)] {
            #expect(!RepoSnapshotWriter.isPlain(bad), "\(bad.debugDescription)")
        }
    }

    @Test func theListingIsReadForRegularBlobsWithinTheLimits() {
        let object = String(repeating: "a", count: 40)
        let blob = { (mode: String, size: Int, path: String) in "\(mode) blob \(object) \(size)\t\(path)" }
        let listing = [
            blob("100644", 5, "a.txt"), blob("100755", 7, "run.sh"), blob("120000", 9, "link"), blob("100644", 99, "big"),
            "160000 commit \(String(repeating: "b", count: 40))       -\tsub", blob("100644", 3, "../escape"), "garbage",
        ].joined(separator: "\0") + "\0"
        let picked = RepoSnapshotWriter.select(listing, RepoSnapshotWriter.Limits(fileBytes: 50, totalBytes: 1000, files: 10))
        #expect(picked.paths == ["a.txt", "run.sh"] && picked.bytes == 12 && picked.left == 5)
    }

    @Test func theConfigKeyIsOnByDefaultAndTakesTrueOrFalse() throws {
        func parse(_ line: String) throws -> Config {
            try Config.parse("\(line)\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n")
        }
        #expect(try parse("").chatReadsRepo)
        #expect(try parse("chat_reads_repo = true").chatReadsRepo)
        #expect(try !parse("chat_reads_repo = false").chatReadsRepo)
        for bad in ["chat_reads_repo = \"no\"", "chat_reads_repo = 0"] {
            #expect(throws: ConfigError.self, "\(bad)") { try parse(bad) }
        }
    }
}
