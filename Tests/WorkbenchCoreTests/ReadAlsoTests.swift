import Foundation
import Testing

@testable import WorkbenchCore

/// Other repositories a run may read: which folders qualify, how the config says it, and what the turn is given.
@Suite struct ReadAlsoResolveTests {
    private func folder(_ name: String, git: Bool = true, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if git { try makeRepository(at: url.appendingPathComponent(".git")) }
        return url
    }

    /// What git calls a git directory: a `HEAD`, an object store and refs.
    private func makeRepository(at git: URL) throws {
        for sub in ["objects", "refs"] {
            try FileManager.default.createDirectory(at: git.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
    }

    private func parent() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("read-also-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test func aSiblingCheckoutIsFoundByRelativeAbsoluteAndHomePaths() throws {
        let dir = try parent()
        let project = try folder("app", in: dir)
        let backend = try folder("backend", in: dir)
        let nested = try folder("shared", in: dir.appendingPathComponent("libs"))
        let home = dir.appendingPathComponent("home")
        let inHome = try folder("tools", in: home)
        let result = ReadAlso.resolve(
            ["../backend", backend.path, "~/tools", "../libs/shared"], projectRoot: project, home: home.path)
        #expect(try result.get().map(\.path) == [backend, inHome, nested].map(\.path), "each once, in the order written")
    }

    @Test func aFolderThatIsMissingNotACheckoutOrTheProjectItselfIsRefusedWithWhy() throws {
        let dir = try parent()
        let project = try folder("app", in: dir)
        _ = try folder("plain", git: false, in: dir)
        _ = try folder("inner", in: project)
        let cases: [(String, String)] = [
            ("../missing", "is not a folder"), ("../plain", "not the root of a git checkout"), (".", "the project itself"),
            ("inner", "inside it"), ("..", "not the root of a git checkout"),
        ]
        for (entry, why) in cases {
            guard case .failure(let problem) = ReadAlso.resolve([entry], projectRoot: project) else {
                Issue.record("'\(entry)' was accepted")
                continue
            }
            #expect(problem.entry == entry && problem.why.contains(why), "\(problem)")
        }
    }

    @Test func aLinkIsFollowedSoItCannotHideWhereItPoints() throws {
        let dir = try parent()
        let project = try folder("app", in: dir)
        let backend = try folder("backend", in: dir)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("alias"), withDestinationURL: backend)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("home-alias"), withDestinationURL: project)
        #expect(try ReadAlso.resolve(["../alias"], projectRoot: project).get().map(\.path) == [backend.path])
        guard case .failure = ReadAlso.resolve(["../home-alias"], projectRoot: project) else {
            Issue.record("a link back to the project was accepted")
            return
        }
    }

    @Test func anEmptyOrStrayDotGitIsNotACheckout() throws {
        let dir = try parent()
        let project = try folder("app", in: dir)
        let empty = try folder("empty-git", git: false, in: dir)
        try FileManager.default.createDirectory(at: empty.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let noRefs = try folder("no-refs", git: false, in: dir)
        try FileManager.default.createDirectory(at: noRefs.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main".write(to: noRefs.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let junk = try folder("junk-file", git: false, in: dir)
        try "not a gitdir line".write(to: junk.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let dangling = try folder("dangling", git: false, in: dir)
        try "gitdir: /no/such/place".write(to: dangling.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        for name in ["empty-git", "no-refs", "junk-file", "dangling"] {
            guard case .failure(let problem) = ReadAlso.resolve(["../\(name)"], projectRoot: project) else {
                Issue.record("\(name) was accepted as a checkout")
                continue
            }
            #expect(problem.why.contains("not the root of a git checkout"), "\(problem)")
        }
    }

    @Test func aLinkedWorktreeOrSubmoduleWhoseDotGitIsAFileIsACheckout() throws {
        let dir = try parent()
        let project = try folder("app", in: dir)
        let main = try folder("main", in: dir)
        // A linked worktree: its `.git` file leads to a folder inside the main repository that has a HEAD and a `commondir`.
        let admin = main.appendingPathComponent(".git/worktrees/linked")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try "ref: refs/heads/linked\n".write(to: admin.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let linked = try folder("linked", git: false, in: dir)
        try "gitdir: \(admin.path)\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(try ReadAlso.resolve(["../linked"], projectRoot: project).get().map(\.path) == [linked.path])
    }

    @Test func aCheckoutThatContainsTheProjectIsRefusedAsAboveIt() throws {
        let dir = try parent()
        try makeRepository(at: dir.appendingPathComponent(".git"))
        let project = try folder("app", in: dir)
        guard case .failure(let problem) = ReadAlso.resolve([".."], projectRoot: project) else {
            Issue.record("the folder above the project was accepted")
            return
        }
        #expect(problem.why.contains("above it"), "\(problem)")
    }

    @Test func aPathAPermissionRuleCouldNotHoldSafelyIsRefused() throws {
        let dir = try parent()
        let project = try folder("app", in: dir)
        for name in ["with space", "star*", "paren(1)", "bracket[1]", "quo'te"] {
            _ = try folder(name, in: dir)
            guard case .failure(let problem) = ReadAlso.resolve(["../\(name)"], projectRoot: project) else {
                Issue.record("'\(name)' was accepted")
                continue
            }
            #expect(problem.why.contains("permission rule"), "\(problem)")
        }
    }
}

@Suite struct ReadAlsoConfigTests {
    private static let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"

    @Test func theListIsReadAsWrittenAndIsEmptyByDefault() throws {
        #expect(try Config.parse("" + Self.tools).readAlso.isEmpty)
        let config = try Config.parse("read_also = [\"../backend\", \"~/shared\"]\n" + Self.tools)
        #expect(config.readAlso == ["../backend", "~/shared"])
    }

    @Test func anEmptyEntryATooLongListOrANonListIsAConfigError() {
        func problems(_ text: String) -> [String] {
            do {
                _ = try Config.parse(text + Self.tools)
                return []
            } catch let error as ConfigError { return error.problems.map(\.message) } catch { return ["\(error)"] }
        }
        #expect(problems("read_also = [\"\"]\n").contains { $0.contains("read_also") && $0.contains("is empty") })
        let six = (1...6).map { "\"../r\($0)\"" }.joined(separator: ", ")
        #expect(problems("read_also = [\(six)]\n").contains { $0.contains("more than 5") })
        #expect(!problems("read_also = \"../backend\"\n").isEmpty)
    }
}

@Suite struct ReadAlsoInvocationTests {
    private static let tools =
        "\n[tools]\navailable = [\"Read\", \"Edit\"]\nallowed = [\"Read\", \"Edit\"]\ndenied = [\"Bash(rm:*)\"]\n"

    private func args(_ folders: [URL], text: String = "") throws -> [String] {
        let config = try Config.parse(text + Self.tools)
        let turn = TurnRequest(sessionID: UUID(), resume: false, budgetUSD: 1, prompt: "go", readDirectories: folders)
        return try config.invocation(for: turn).arguments
    }

    @Test func eachFolderIsAddedAndEveryWriteToItIsDeniedWithAnAbsolutePathRule() throws {
        let one = URL(fileURLWithPath: "/work/backend")
        let two = URL(fileURLWithPath: "/work/shared")
        let argv = try args([one, two])
        let add = try #require(argv.firstIndex(of: "--add-dir"))
        #expect(Array(argv[(add + 1)...(add + 2)]) == ["/work/backend", "/work/shared"])
        #expect(add < (try #require(argv.firstIndex(of: "--tools"))), "before the variadic tool lists")
        let denied = try #require(argv.firstIndex(of: "--disallowedTools"))
        let rules = Array(argv[(denied + 1)...].prefix { !$0.hasPrefix("--") })
        #expect(rules.contains("Bash(rm:*)"), "the project's own denials stay")
        for tool in ["Edit", "Write", "NotebookEdit"] {
            #expect(rules.contains("\(tool)(//work/backend/**)") && rules.contains("\(tool)(//work/shared/**)"), "\(rules)")
        }
        #expect(argv.last == "go" && argv[argv.count - 2] == "--", "the prompt still follows --")
    }

    @Test func withNoFoldersNothingIsAddedAndNothingExtraIsDenied() throws {
        let argv = try args([])
        #expect(!argv.contains("--add-dir"))
        let denied = try #require(argv.firstIndex(of: "--disallowedTools"))
        #expect(Array(argv[(denied + 1)...].prefix { !$0.hasPrefix("--") }) == ["Bash(rm:*)"])
    }
}

@Suite(.processGate) struct ReadAlsoRunTests {
    private func sibling(_ fx: RunnerFixture) async throws -> URL {
        let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("backend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await fx.git.run(["init", "-q"], in: dir)
        return dir.resolvingSymlinksInPath()
    }

    private func dumped(_ path: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    private func setReadAlso(_ entries: [String], in fx: RunnerFixture) throws {
        let text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        let list = entries.map { "\"\($0)\"" }.joined(separator: ", ")
        try ("read_also = [\(list)]\n" + text).write(to: fx.project.configURL, atomically: true, encoding: .utf8)
    }

    @Test func aRunGivesTheTurnTheFolderReadOnlyAndTellsItSo() async throws {
        let fx = try await RunnerFixture()
        let backend = try await sibling(fx)
        try setReadAlso([backend.path], in: fx)
        let id = try await fx.approvedThread()
        let dump = FakeClaude.scratch("dump.json")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        let report = try await fx.runner(id).run(fx.options("dump=\(dump)"))
        #expect(report.result == .succeeded)

        let seen = try dumped(dump)
        let argv = try #require(seen["argv"] as? [String])
        let add = try #require(argv.firstIndex(of: "--add-dir"))
        #expect(argv[add + 1] == backend.path)
        #expect(argv.contains("Edit(/\(backend.path)/**)") && argv.contains("Write(/\(backend.path)/**)"))
        let prompt = try String(contentsOf: fx.project.promptURL(id, turn: 1), encoding: .utf8)
        #expect(prompt.contains(backend.path), "the first prompt names the folder: \(prompt)")
    }

    @Test func aRunWithoutReadAlsoAddsNoFolderAndNoSection() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let dump = FakeClaude.scratch("dump.json")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        _ = try await fx.runner(id).run(fx.options("dump=\(dump)"))
        let seen = try dumped(dump)
        #expect(!(try #require(seen["argv"] as? [String])).contains("--add-dir"))
    }

    @Test func aFolderThatGoesAwayAfterTheFirstTurnRefusesTheNextTurnInsteadOfStartingItWithoutTheAccess() async throws {
        let fx = try await RunnerFixture()
        let backend = try await sibling(fx)
        try setReadAlso([backend.path], in: fx)
        let id = try await fx.approvedThread()
        let first = try await fx.runner(id).run(fx.options("stream-events=1"))
        #expect(first.result == .succeeded)
        let turnsBefore = try fx.events(id).filter { $0.kind == .turnStarted }.count

        try FileManager.default.removeItem(at: backend)
        do {
            _ = try await fx.runner(id).run(fx.options("stream-events=1", feedback: "Again."))
            Issue.record("the second turn started without the folder")
        } catch let error as RunnerError {
            #expect("\(error)".contains("read_also"), "\(error)")
        }
        #expect(try fx.events(id).filter { $0.kind == .turnStarted }.count == turnsBefore, "no second turn was started")
    }

    @Test func aFolderTheRunCannotBeGivenStopsItBeforeAnyTurnAndSaysWhich() async throws {
        let fx = try await RunnerFixture()
        try setReadAlso(["../no-such-checkout"], in: fx)
        let id = try await fx.approvedThread()
        do {
            _ = try await fx.runner(id).run(fx.options("stream-events=1"))
            Issue.record("the run started")
        } catch let error as RunnerError {
            #expect("\(error)".contains("no-such-checkout") && "\(error)".contains("read_also"), "\(error)")
        }
        #expect(!(try fx.events(id)).contains { $0.kind == .turnStarted }, "no turn was started")
    }
}
