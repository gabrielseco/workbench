import Foundation
import Testing

@testable import WorkbenchCore

private func scratch(_ label: String = "new") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wb-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func listing(_ url: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
}

private final class CopyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

// MARK: global config

@Suite struct GlobalConfigTests {
    @Test func anAbsentFileIsEmpty() throws {
        let missing = try scratch().appendingPathComponent("nope.toml")
        #expect(try GlobalConfig.load(from: missing) == GlobalConfig())
    }

    @Test func readsTheThreeKeysAndExpandsTilde() throws {
        let config = try GlobalConfig.parse(
            """
            projects_dir = "~/code"
            claude_path = "/opt/bin/claude"
            model = "haiku"
            """, home: "/Users/x")
        #expect(config.projectsDirectory?.path == "/Users/x/code")
        #expect(config.claudePath == "/opt/bin/claude")
        #expect(config.model == "haiku")
    }

    @Test func aRelativeProjectsDirIsRefused() throws {
        #expect(throws: ConfigError.self) { try GlobalConfig.parse("projects_dir = \"code\"") }
    }

    @Test func projectOnlyKeysAreNotAllowedAndTheFileIsNamed() throws {
        let file = try scratch().appendingPathComponent("config.toml")
        try write("check_command = \"make\"\n[tools]\navailable = [\"Read\"]\n", to: file)
        do {
            _ = try GlobalConfig.load(from: file)
            Issue.record("expected a ConfigError")
        } catch let error as ConfigError {
            let text = error.description
            #expect(text.contains(file.path))
            #expect(text.contains("'check_command' is not allowed in the global config"))
            #expect(text.contains("[tools]"))
        }
    }

    @Test func aBadModelIsAnInvalidValue() throws {
        #expect(throws: ConfigError.self) { try GlobalConfig.parse("model = \"--evil\"") }
    }

    @Test func defaultLocationFollowsXDGThenHome() {
        #expect(
            GlobalConfig.defaultURL(environment: ["HOME": "/h"]).path == "/h/.config/workbench/config.toml")
        #expect(
            GlobalConfig.defaultURL(environment: ["HOME": "/h", "XDG_CONFIG_HOME": "/x"]).path
                == "/x/workbench/config.toml")
    }

    @Test func theProjectTemplateTakesTheDefaultsAndStillParses() throws {
        let text = Config.exampleTOML(claudePath: "/opt/claude \"x\"", model: "opus")
        let config = try Config.parse(text)
        #expect(config.claudePath == "/opt/claude \"x\"")
        #expect(config.model == "opus")
        #expect(try Config.parse(Config.exampleTOML(claudePath: nil, model: nil)).model == nil)
    }
}

// MARK: creating

@Suite struct ProjectCreatorTests {
    private func creator() throws -> ProjectCreator { ProjectCreator(git: try isolatedGit()) }

    @Test func makesARepoWithOneEmptyCommitAndAConfigThatGitStatusDoesNotShow() async throws {
        let parent = try scratch()
        let git = try isolatedGit()
        let root = try await creator().create(NewProjectRequest(name: "mocks-kit", parent: parent))
        #expect(root == parent.appendingPathComponent("mocks-kit").resolvingSymlinksInPath())
        #expect(try await git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: root).stdout == "main\n")
        #expect(try await git.run(["rev-list", "--count", "HEAD"], in: root).stdout == "1\n")
        #expect(try await git.run(["ls-tree", "-r", "HEAD"], in: root).stdout.isEmpty)
        #expect(try await git.run(["status", "--porcelain"], in: root).stdout.isEmpty)
        let config = try Config.load(from: Project(root: root).configURL)
        #expect(config.model == nil)
    }

    @Test func defaultsFromTheGlobalConfigLandInTheProjectConfig() async throws {
        let parent = try scratch()
        let root = try await creator().create(
            NewProjectRequest(
                name: "p", parent: parent, defaults: GlobalConfig(claudePath: "/opt/claude", model: "haiku")))
        let config = try Config.load(from: Project(root: root).configURL)
        #expect(config.claudePath == "/opt/claude")
        #expect(config.model == "haiku")
    }

    @Test func badNamesAreRefusedBeforeAnythingIsCreated() async throws {
        let parent = try scratch()
        for name in ["", ".", "..", "../x", "a/b", "-rf", "a b", "x.git", "a..b", "trailing.", ".hidden"] {
            await #expect(throws: NewProjectError.invalidName(name)) {
                try await creator().create(NewProjectRequest(name: name, parent: parent))
            }
        }
        #expect(listing(parent).isEmpty)
    }

    @Test func aNonEmptyTargetIsRefusedAndUntouched() async throws {
        let parent = try scratch()
        let target = parent.appendingPathComponent("p")
        try write("mine\n", to: target.appendingPathComponent("keep.txt"))
        await #expect(throws: NewProjectError.targetNotEmpty(target.path)) {
            try await creator().create(NewProjectRequest(name: "p", parent: parent))
        }
        #expect(listing(target) == ["keep.txt"])
    }

    @Test func anEmptyExistingDirectoryIsUsed() async throws {
        let parent = try scratch()
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("p"), withIntermediateDirectories: true)
        let root = try await creator().create(NewProjectRequest(name: "p", parent: parent))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    }

    @Test func aFileInTheWayIsRefused() async throws {
        let parent = try scratch()
        try write("x", to: parent.appendingPathComponent("p"))
        await #expect(throws: NewProjectError.self) {
            try await creator().create(NewProjectRequest(name: "p", parent: parent))
        }
    }

    @Test func insideAnotherRepoIsRefusedUnlessNested() async throws {
        let outer = try scratch()
        let git = try isolatedGit()
        _ = try await git.run(["init", "-q", "-b", "main"], in: outer)
        let refused = try? await creator().create(NewProjectRequest(name: "p", parent: outer))
        #expect(refused == nil)
        #expect(listing(outer) == [".git"])

        // A parent that does not exist yet, below the repo, is still inside it.
        let deeper = outer.appendingPathComponent("a/b")
        await #expect(throws: NewProjectError.self) {
            try await creator().create(NewProjectRequest(name: "p", parent: deeper))
        }
        #expect(!FileManager.default.fileExists(atPath: outer.appendingPathComponent("a").path))

        let root = try await creator().create(NewProjectRequest(name: "p", parent: outer, nested: true))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    }

    @Test func theRefusalNamesTheEnclosingRepository() async throws {
        let outer = try scratch()
        _ = try await isolatedGit().run(["init", "-q", "-b", "main"], in: outer)
        do {
            try await creator().create(NewProjectRequest(name: "p", parent: outer))
            Issue.record("expected a refusal")
        } catch let error as NewProjectError {
            #expect(error.description.contains(outer.path))
            #expect(error.description.contains("--nested"))
        }
    }

    @Test func missingParentsAreCreated() async throws {
        let base = try scratch()
        let parent = base.appendingPathComponent("a/b")
        let seed = base.appendingPathComponent("seed")
        try write("x\n", to: seed.appendingPathComponent("f.txt"))
        let ok = try await creator().create(NewProjectRequest(name: "p", parent: parent, seeds: [seed]))
        #expect(FileManager.default.fileExists(atPath: ok.appendingPathComponent("vendor/seed/f.txt").path))
    }

    // MARK: seeds

    @Test func seedsAreCopiedIntoVendorAndCommittedSeparately() async throws {
        let base = try scratch()
        let git = try isolatedGit()
        let dir = base.appendingPathComponent("mocks")
        try write("a\n", to: dir.appendingPathComponent("a.ts"))
        try write("b\n", to: dir.appendingPathComponent("deep/b.ts"))
        try write("nested repo\n", to: dir.appendingPathComponent(".git/HEAD"))
        let file = base.appendingPathComponent("helper.ts")
        try write("h\n", to: file)

        let root = try await creator().create(
            NewProjectRequest(name: "kit", parent: base.appendingPathComponent("out"), seeds: [dir, file]))
        #expect(listing(root.appendingPathComponent("vendor")) == ["helper.ts", "mocks"])
        #expect(listing(root.appendingPathComponent("vendor/mocks")) == ["a.ts", "deep"])
        #expect(try await git.run(["rev-list", "--count", "HEAD"], in: root).stdout == "2\n")
        #expect(try await git.run(["status", "--porcelain"], in: root).stdout.isEmpty)
        let tracked = try await git.run(["ls-files"], in: root).stdout
        #expect(tracked.contains("vendor/mocks/deep/b.ts") && !tracked.contains(".git/"))
    }

    @Test func aSymlinkSeedOrASymlinkInsideASeedIsRefusedAndNothingIsCreated() async throws {
        let base = try scratch()
        let real = base.appendingPathComponent("real")
        try write("x\n", to: real.appendingPathComponent("f.txt"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let inner = base.appendingPathComponent("inner")
        try write("y\n", to: inner.appendingPathComponent("g.txt"))
        try FileManager.default.createSymbolicLink(
            at: inner.appendingPathComponent("out"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let parent = base.appendingPathComponent("out")

        for seed in [link, inner] {
            await #expect(throws: NewProjectError.self) {
                try await creator().create(NewProjectRequest(name: "p", parent: parent, seeds: [seed]))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: parent.path))
    }

    @Test func aMissingSeedIsRefusedBeforeAnythingIsCreated() async throws {
        let base = try scratch()
        let missing = base.appendingPathComponent("nope")
        await #expect(throws: NewProjectError.seedNotFound(missing.path)) {
            try await creator().create(
                NewProjectRequest(name: "p", parent: base.appendingPathComponent("out"), seeds: [missing]))
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("out").path))
    }

    @Test func twoSeedsWithTheSameNameCollide() async throws {
        let base = try scratch()
        let a = base.appendingPathComponent("one/mocks")
        let b = base.appendingPathComponent("two/mocks")
        try write("a\n", to: a.appendingPathComponent("f.ts"))
        try write("b\n", to: b.appendingPathComponent("f.ts"))
        await #expect(throws: NewProjectError.seedCollision("mocks")) {
            try await creator().create(
                NewProjectRequest(name: "p", parent: base.appendingPathComponent("out"), seeds: [a, b]))
        }
    }

    @Test func aFailureAfterCreationStartedRemovesWhatWasMade() async throws {
        // A git that has no identity fails at the first commit, after the directory exists.
        let base = try scratch()
        let bare = try GitRunner.discover(
            extraEnvironment: [
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                "GIT_AUTHOR_NAME": "", "GIT_AUTHOR_EMAIL": "", "GIT_COMMITTER_NAME": "", "GIT_COMMITTER_EMAIL": "",
                "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "user.useConfigOnly", "GIT_CONFIG_VALUE_0": "true",
            ])
        let parent = base.appendingPathComponent("a")
        await #expect(throws: NewProjectError.self) {
            try await ProjectCreator(git: bare).create(NewProjectRequest(name: "p", parent: parent))
        }
        #expect(!FileManager.default.fileExists(atPath: parent.path))

        // A directory that was already there stays, emptied of what `new` wrote.
        let existing = base.appendingPathComponent("e/p")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        await #expect(throws: NewProjectError.self) {
            try await ProjectCreator(git: bare).create(
                NewProjectRequest(name: "p", parent: existing.deletingLastPathComponent()))
        }
        #expect(FileManager.default.fileExists(atPath: existing.path))
        #expect(listing(existing).isEmpty)
    }

    @Test func aSeedThatContainsTheTargetIsRefusedBeforeItCopiesItself() async throws {
        let base = try scratch()
        let seed = base.appendingPathComponent("source")
        try write("x\n", to: seed.appendingPathComponent("f.txt"))
        let inside = seed.appendingPathComponent("kit")
        await #expect(throws: NewProjectError.self) {
            try await creator().create(NewProjectRequest(name: "kit", parent: seed, seeds: [seed]))
        }
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        // The other way round: a seed inside the target's own place.
        let target = base.appendingPathComponent("proj")
        try write("y\n", to: target.appendingPathComponent("s/f.txt"))
        await #expect(throws: NewProjectError.self) {
            try await creator().create(
                NewProjectRequest(name: "proj", parent: base, seeds: [target.appendingPathComponent("s")]))
        }
    }

    @Test func anEmptySeedDirectoryStillMakesAProject() async throws {
        let base = try scratch()
        let seed = base.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try write("meta\n", to: seed.appendingPathComponent(".git/HEAD"))
        let git = try isolatedGit()
        let root = try await creator().create(
            NewProjectRequest(name: "p", parent: base.appendingPathComponent("out"), seeds: [seed]))
        #expect(try await git.run(["rev-list", "--count", "HEAD"], in: root).stdout == "2\n")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("vendor/empty").path))
    }

    @Test func anUnreadableSeedIsRefusedBeforeAnythingIsCreated() async throws {
        let base = try scratch()
        let seed = base.appendingPathComponent("locked")
        let file = seed.appendingPathComponent("secret.ts")
        try write("x\n", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let out = base.appendingPathComponent("out")
        guard !FileManager.default.isReadableFile(atPath: file.path) else { return }  // running as root
        do {
            try await creator().create(NewProjectRequest(name: "p", parent: out, seeds: [seed]))
            Issue.record("expected the unreadable seed to be refused")
        } catch let error as NewProjectError {
            if case .seedUnreadable(let path) = error {
                #expect(path.hasSuffix("locked/secret.ts"))
            } else {
                Issue.record("wrong error: \(error)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func aTargetThatIsALinkIsRefusedSoTheNestingCheckCannotBeSidestepped() async throws {
        let base = try scratch()
        let outer = base.appendingPathComponent("outer")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        _ = try await isolatedGit().run(["init", "-q", "-b", "main"], in: outer)
        let empty = outer.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let parent = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent("kit"), withDestinationURL: empty)
        await #expect(throws: NewProjectError.self) {
            try await creator().create(NewProjectRequest(name: "kit", parent: parent))
        }
        #expect(listing(empty).isEmpty)
    }

    @Test func aFailureAfterTheSeedsWereCopiedLeavesNothingBehind() async throws {
        // A pre-commit hook that rejects a tree containing vendor/ fails the second commit, after the copy.
        let base = try scratch()
        let hooks = base.appendingPathComponent("hooks")
        let hook = hooks.appendingPathComponent("pre-commit")
        try write("#!/bin/sh\n[ -d vendor ] && exit 1\nexit 0\n", to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let git = try GitRunner.discover(
            extraEnvironment: [
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
                "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": hooks.path,
            ])
        let seed = base.appendingPathComponent("seed")
        try write("x\n", to: seed.appendingPathComponent("f.txt"))
        let parent = base.appendingPathComponent("out")
        await #expect(throws: NewProjectError.self) {
            try await ProjectCreator(git: git).create(NewProjectRequest(name: "p", parent: parent, seeds: [seed]))
        }
        #expect(!FileManager.default.fileExists(atPath: parent.path))
    }

    @Test func ignoredSeedFilesAreStillCommittedAndSoReachTheWorktree() async throws {
        let base = try scratch()
        let seed = base.appendingPathComponent("mocks")
        try write("*.ts\n", to: seed.appendingPathComponent(".gitignore"))
        try write("h\n", to: seed.appendingPathComponent("helper.ts"))
        let git = try isolatedGit()
        let root = try await creator().create(
            NewProjectRequest(name: "p", parent: base.appendingPathComponent("out"), seeds: [seed]))
        let tracked = try await git.run(["ls-files"], in: root).stdout
        #expect(tracked.contains("vendor/mocks/helper.ts"), "\(tracked)")
        #expect(try await git.run(["status", "--porcelain"], in: root).stdout.isEmpty)
    }

    @Test func aCopyThatFailsAfterOneFileLeavesNothingBehind() async throws {
        let base = try scratch()
        let seed = base.appendingPathComponent("seed")
        for name in ["a.ts", "b.ts", "c.ts"] { try write("x\n", to: seed.appendingPathComponent(name)) }
        let bystander = base.appendingPathComponent("bystander.txt")
        try write("mine\n", to: bystander)

        struct Boom: Error {}
        let copied = CopyCounter()
        var failing = ProjectCreator(git: try isolatedGit())
        failing.beforeCopy = { _ in if copied.next() > 2 { throw Boom() } }

        // A target the call makes, below parents the call makes.
        let parent = base.appendingPathComponent("a/b")
        await #expect(throws: Boom.self) {
            try await failing.create(NewProjectRequest(name: "p", parent: parent, seeds: [seed]))
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("a").path))

        // A target that was already there stays, empty.
        let existing = base.appendingPathComponent("e")
        try FileManager.default.createDirectory(
            at: existing.appendingPathComponent("p"), withIntermediateDirectories: true)
        let again = CopyCounter()
        failing.beforeCopy = { _ in if again.next() > 2 { throw Boom() } }
        await #expect(throws: Boom.self) {
            try await failing.create(NewProjectRequest(name: "p", parent: existing, seeds: [seed]))
        }
        #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("p").path))
        #expect(listing(existing.appendingPathComponent("p")).isEmpty)
        #expect(try String(contentsOf: bystander, encoding: .utf8) == "mine\n")
        #expect(listing(seed) == ["a.ts", "b.ts", "c.ts"])
    }

    @Test func aSeedOverTheFileLimitIsRefused() async throws {
        let base = try scratch()
        let seed = base.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        for i in 0...ProjectCreator.maxSeedFiles {
            FileManager.default.createFile(atPath: seed.appendingPathComponent("f\(i)").path, contents: Data())
        }
        await #expect(throws: NewProjectError.self) {
            try await creator().create(
                NewProjectRequest(name: "p", parent: base.appendingPathComponent("out"), seeds: [seed]))
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("out").path))
    }
}
