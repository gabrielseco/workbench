import CryptoKit
import Foundation
import Testing

@testable import WorkbenchCore

private let framing =
    "These are the project's instructions for anyone working in this repository. Where they describe "
    + "pushing, opening or merging pull requests, Workbench does that after your work is reviewed: commit in "
    + "this worktree and stop there."

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Whether the event has an `instructions` field at all, `null` included.
private func records(_ event: Event) -> Bool {
    if case .object(let fields) = event.data { return fields.keys.contains("instructions") }
    return false
}

extension RunnerFixture {
    /// Writes and commits files (and symlinks, name to target) under `root`, and returns the new commit.
    @discardableResult
    func commit(
        _ files: [String: String] = [:], data: [String: Data] = [:], links: [String: String] = [:],
        in root: URL? = nil
    ) async throws -> String {
        let root = root ?? repo
        var contents = data
        for (name, text) in files { contents[name] = Data(text.utf8) }
        for (name, bytes) in contents {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        for (name, target) in links {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
        }
        for name in Array(contents.keys) + Array(links.keys) {
            let added = try await git.run(["add", "--", name], in: root)
            #expect(added.succeeded, "git add \(name): \(added.stderr)")
        }
        let committed = try await git.run(["commit", "-q", "-m", "files"], in: root)
        #expect(committed.succeeded, "git commit: \(committed.stderr)")
        return try await git.run(["rev-parse", "HEAD"], in: root).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func instructions(at commit: String) async throws -> ProjectInstructions? {
        try await ProjectInstructionsLoader(git: git, repo: repo, commit: commit)?.load()
    }

    func prompt(_ id: String, turn: Int) throws -> String {
        try String(contentsOf: project.promptURL(id, turn: turn), encoding: .utf8)
    }

    func starts(_ id: String) throws -> [Event] { try events(id).filter { $0.kind == .turnStarted } }
}

@Suite struct InstructionsLoaderTests {
    // MARK: which file

    @Test func agentsWinsOverClaude() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit(["AGENTS.md": "from agents\n", "CLAUDE.md": "from claude\n"])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.file == "AGENTS.md")
        #expect(found.text == "from agents")
        #expect(!found.truncated)
        #expect(found.skipped.isEmpty)
    }

    @Test func claudeIsUsedWhenThereIsNoAgents() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit(["CLAUDE.md": "from claude\n"])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.file == "CLAUDE.md")
        #expect(found.text == "from claude")
    }

    @Test func neitherFileMeansNoInstructions() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit(["README.md": "hello\n"])
        #expect(try await fx.instructions(at: commit) == nil)
    }

    @Test func aSymlinkedAgentsCountsAsAbsent() async throws {
        let fx = try await RunnerFixture()
        let alone = try await fx.commit(["real.md": "linked text\n"], links: ["AGENTS.md": "real.md"])
        #expect(try await fx.instructions(at: alone) == nil)

        let withClaude = try await fx.commit(["CLAUDE.md": "from claude\n"])
        #expect(try await fx.instructions(at: withClaude)?.file == "CLAUDE.md")
    }

    @Test func aDirectoryNamedAgentsCountsAsAbsent() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit(["AGENTS.md/inner.md": "inner\n"])
        #expect(try await fx.instructions(at: commit) == nil)
    }

    @Test func onlyAFullCommitIDIsAccepted() async throws {
        let fx = try await RunnerFixture()
        #expect(ProjectInstructionsLoader(git: fx.git, repo: fx.repo, commit: "main") == nil)
        #expect(ProjectInstructionsLoader(git: fx.git, repo: fx.repo, commit: "--help") == nil)
        #expect(ProjectInstructionsLoader(git: fx.git, repo: fx.repo, commit: "abc123") == nil)
    }

    // MARK: imports

    @Test func importsInTheCommitAreExpandedRelativeToTheImportingFile() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit([
            "AGENTS.md": "top\n@docs/a.md\n@./plain.md\nend\n",
            "docs/a.md": "A\n@b.md\n@../plain2.md\n",
            "docs/b.md": "B\n",
            "plain.md": "plain\n",
            "plain2.md": "plain two\n",
        ])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.text == "top\nA\nB\nplain two\nplain\nend")
        #expect(found.skipped.isEmpty)
    }

    @Test func claudeThatOnlyImportsAgentsIsExpanded() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit(["CLAUDE.md": "@rules.md\n", "rules.md": "the rules\n"])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.file == "CLAUDE.md")
        #expect(found.text == "the rules")
    }

    @Test(arguments: [
        ("/etc/passwd", ProjectInstructions.SkipReason.absolute),
        ("~/.claude/CLAUDE.md", .absolute),
        ("../outside.md", .outsideWorktree),
        ("docs/../../outside.md", .outsideWorktree),
        ("link.md", .symlink),
        ("linkdir/inner.md", .missing),
        ("nope.md", .missing),
        ("docs", .notAFile),
        ("AGENTS.md", .alreadyIncluded),
    ])
    func anImportThatCannotBeFollowedStaysLiteralAndIsListed(
        path: String, reason: ProjectInstructions.SkipReason
    ) async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit(
            ["AGENTS.md": "before\n@\(path)\nafter\n", "docs/inner.md": "inner\n", "real.md": "secret\n"],
            links: ["link.md": "real.md", "linkdir": "docs"])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.text == "before\n@\(path)\nafter")
        #expect(found.skipped == [.init(path: path, reason: reason)])
    }

    @Test func aCycleIsCutAndAFileIsIncludedOnce() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit([
            "AGENTS.md": "top\n@a.md\n@a.md\n",
            "a.md": "A\n@b.md\n",
            "b.md": "B\n@a.md\n",
        ])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.text == "top\nA\nB\n@a.md\n@a.md")
        #expect(found.skipped.map(\.path) == ["a.md", "a.md"])
        #expect(found.skipped.allSatisfy { $0.reason == .alreadyIncluded })
    }

    @Test func importsStopAtDepthThree() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit([
            "AGENTS.md": "top\n@one.md\n",
            "one.md": "1\n@two.md\n",
            "two.md": "2\n@three.md\n",
            "three.md": "3\n@four.md\n",
            "four.md": "4\n",
        ])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.text == "top\n1\n2\n3\n@four.md")
        #expect(found.skipped == [.init(path: "four.md", reason: .tooDeep)])
    }

    @Test func linesInsideAFencedCodeBlockAreNeverExpanded() async throws {
        let fx = try await RunnerFixture()
        let text = "top\n```\n@a.md\n```\n~~~sh\n@a.md\n```\n@a.md\n~~~\n@a.md\n"
        let commit = try await fx.commit(["AGENTS.md": text, "a.md": "A\n"])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.text == "top\n```\n@a.md\n```\n~~~sh\n@a.md\n```\n@a.md\n~~~\nA")
        #expect(found.skipped.isEmpty)
    }

    @Test func onlyALineThatIsExactlyAnImportIsOne() async throws {
        let fx = try await RunnerFixture()
        let text = "ask @a.md about it\n@a.md and more\n @a.md\n@\n"
        let commit = try await fx.commit(["AGENTS.md": text, "a.md": "A\n"])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.text == String(text.dropLast()))
        #expect(found.skipped.isEmpty)
    }

    @Test func theNumberOfImportsIsBounded() async throws {
        let fx = try await RunnerFixture()
        let count = ProjectInstructionsLoader.maxImports + 2
        var files = ["AGENTS.md": (0..<count).map { "@f\($0).md\n" }.joined()]
        for i in 0..<count { files["f\(i).md"] = "\(i)\n" }
        let commit = try await fx.commit(files)
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.skipped.map(\.reason) == [.tooMany, .tooMany])
    }

    // MARK: size and encoding

    @Test func oversizedTextIsCutAtALineBoundaryWithTheMarker() async throws {
        let fx = try await RunnerFixture()
        // "é" starts at byte 16383 and ends at 16384, across the cap.
        let first = String(repeating: "a", count: 16000)
        let second = String(repeating: "b", count: 382) + "é" + String(repeating: "c", count: 500)
        let commit = try await fx.commit(["AGENTS.md": first + "\n" + second + "\nlast\n"])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.truncated)
        #expect(found.text == first + "\n[project instructions truncated at 16384 bytes]")
        #expect(found.bytes == found.text.utf8.count)
    }

    @Test func aSingleOversizedLineIsNotCutInsideACharacter() {
        let line = String(repeating: "a", count: 16383) + "é" + String(repeating: "c", count: 100)
        let (text, truncated) = ProjectInstructionsLoader.capped(line)
        #expect(truncated)
        #expect(text == String(repeating: "a", count: 16383) + "\n[project instructions truncated at 16384 bytes]")
    }

    @Test func textAtTheCapIsNotTruncated() {
        let exact = String(repeating: "a", count: 16383) + "\n"
        #expect(ProjectInstructionsLoader.capped(exact) == (exact, false))
        let lines = String(repeating: "a", count: 16384) + "\nmore"
        let cut = ProjectInstructionsLoader.capped(lines)
        #expect(cut.truncated)
        #expect(cut.text == String(repeating: "a", count: 16384) + "\n[project instructions truncated at 16384 bytes]")
    }

    @Test func aHugeBlobIsReadOnlyInPartAndTruncated() async throws {
        let fx = try await RunnerFixture()
        let line = String(repeating: "x", count: 99) + "\n"
        let commit = try await fx.commit([
            "AGENTS.md": "@big.md\n", "big.md": String(repeating: line, count: 5000),
        ])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.truncated)
        #expect(found.text.hasSuffix("\n[project instructions truncated at 16384 bytes]"))
        #expect(found.bytes <= 16384 + 1 + ProjectInstructionsLoader.truncationMarker.utf8.count)
    }

    @Test func bomCrlfAndInvalidUtf8AreNormalizedBeforeHashing() async throws {
        let fx = try await RunnerFixture()
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("one\r\ntw".utf8))
        bytes.append(0xFF)
        bytes.append(Data("o\r\n".utf8))
        let commit = try await fx.commit(data: ["AGENTS.md": bytes])
        let found = try #require(try await fx.instructions(at: commit))
        #expect(found.text == "one\ntw\u{FFFD}o")
        #expect(found.sha256 == sha256("one\ntw\u{FFFD}o"))
    }
}

@Suite struct InstructionsRunTests {
    private static let checked = "check_command = \"scripts/check.sh\""

    // MARK: the prompt and the event

    @Test func theFirstPromptCarriesTheSectionAndAFeedbackTurnDoesNot() async throws {
        let fx = try await RunnerFixture(extraConfig: Self.checked)
        try await fx.commit(["AGENTS.md": "# Rules\n\nUse tabs.\n@more.md\n@nope.md\n", "more.md": "And tests.\n"])
        let id = try await fx.approvedThread()
        let sessions = FakeClaude.scratch("sessions")
        defer { try? FileManager.default.removeItem(atPath: sessions) }

        let first = try await fx.runner(id).run(fx.options("sessions=\(sessions)"))
        #expect(first.result == .succeeded)

        let text = "# Rules\n\nUse tabs.\nAnd tests.\n@nope.md"
        let prompt = try fx.prompt(id, turn: 1)
        #expect(prompt.contains("\n## Project instructions\n\n\(framing)\n\n\(text)\n\n## Checking your work\n"))
        let outOfScope = try #require(prompt.range(of: "\n## Out of scope\n"))
        let section = try #require(prompt.range(of: "\n## Project instructions\n"))
        let checking = try #require(prompt.range(of: "\n## Checking your work\n"))
        #expect(outOfScope.upperBound <= section.lowerBound)
        #expect(section.upperBound <= checking.lowerBound)

        let recorded = try #require(try fx.starts(id).first?.data["instructions"])
        #expect(
            recorded == [
                "file": "AGENTS.md", "sha256": .string(sha256(text)), "bytes": .int(text.utf8.count),
                "truncated": false, "skipped": ["nope.md"],
            ])

        let second = try await fx.runner(id).run(fx.options("sessions=\(sessions)", feedback: "Use spaces."))
        #expect(second.turn == 2)
        let followUp = try fx.prompt(id, turn: 2)
        #expect(!followUp.contains("## Project instructions"))
        #expect(!followUp.contains("Use tabs."))
        let starts = try fx.starts(id)
        #expect(starts.count == 2)
        #expect(records(starts[0]) && !records(starts[1]))
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func withoutACheckCommandTheSectionStillFollowsOutOfScope() throws {
        let goal = try GoalFile.parse(
            """
            ---
            id: g-1
            title: t
            base: main
            budget_usd: 1
            turn_timeout_min: 5
            ---

            ## Request

            Do it.

            ## Criteria

            - [c1] Done.
              - proof: look

            ## Out of scope

            - Nothing else.
            """
        ).goal
        let instructions = ProjectInstructions(file: "AGENTS.md", text: "Use tabs.", truncated: false, skipped: [])
        let prompt = PromptBuilder.firstPrompt(goal: goal, checkCommand: nil, instructions: instructions)
        #expect(prompt.contains("- Nothing else.\n\n## Project instructions\n\n\(framing)\n\nUse tabs.\n\nWork in"))
        #expect(!PromptBuilder.firstPrompt(goal: goal, checkCommand: nil).contains("Project instructions"))
    }

    @Test func noInstructionsFileMeansNoSectionAndANullRecord() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        #expect(!(try fx.prompt(id, turn: 1)).contains("## Project instructions"))
        #expect(try fx.starts(id).first?.data["instructions"] == JSONValue.null)
    }

    @Test func aFirstTurnThatFailsGetsTheSectionAgain() async throws {
        let fx = try await RunnerFixture()
        try await fx.commit(["AGENTS.md": "Use tabs.\n"])
        let id = try await fx.approvedThread()

        let failed = try await fx.runner(id).run(fx.options("exit=2"))
        #expect(failed.result == .failed)
        let again = try await fx.runner(id).run(fx.options())
        #expect(again.result == .succeeded)
        #expect(again.turn > failed.turn)

        #expect(try fx.prompt(id, turn: again.turn) == (try fx.prompt(id, turn: 1)))
        #expect(try fx.prompt(id, turn: again.turn).contains("## Project instructions\n\n\(framing)\n\nUse tabs.\n"))
        let starts = try fx.starts(id)
        #expect(starts.count == again.turn)
        for start in starts {
            #expect(start.data["instructions"]?["file"] == "AGENTS.md")
            #expect(start.data["instructions"]?["sha256"]?.stringValue == sha256("Use tabs."))
        }
    }

    // MARK: opting out

    @Test func projectInstructionsCanBeTurnedOff() async throws {
        let fx = try await RunnerFixture(extraConfig: "project_instructions = false")
        try await fx.commit(["AGENTS.md": "Use tabs.\n"])
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let prompt = try fx.prompt(id, turn: 1)
        #expect(!prompt.contains("## Project instructions"))
        #expect(!prompt.contains("Use tabs."))
        #expect(try fx.starts(id).first?.data["instructions"] == JSONValue.null)
    }

    @Test func theConfigKeyDefaultsToTrueAndMustBeABoolean() throws {
        let tools = "[tools]\navailable = [\"Read\"]"
        #expect(try Config.parse(tools).projectInstructions)
        #expect(try Config.parse("project_instructions = true\n\(tools)").projectInstructions)
        #expect(try !Config.parse("project_instructions = false\n\(tools)").projectInstructions)

        do {
            _ = try Config.parse("model = \"haiku\"\nproject_instructions = \"no\"\n\(tools)")
            Issue.record("a string was accepted")
        } catch let error as ConfigError {
            #expect(error.problems.map(\.code) == [.wrongType])
            #expect(error.problems.map(\.line) == [2])
            #expect(error.problems.first?.message.contains("'project_instructions' must be true or false") == true)
        }
    }

    // MARK: the base commit

    @Test func theBaseCommitIsRecordedWhenTheThreadIsCreated() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit(["AGENTS.md": "Use tabs.\n"])
        let id = try await fx.approvedThread()
        let created = try #require(try fx.events(id).first { $0.kind == .threadCreated })
        #expect(created.data["base_commit"]?.stringValue == commit)
    }

    @Test func aBaseThatMovesBeforeTheFirstRunChangesNeitherTheWorktreeNorThePrompt() async throws {
        let fx = try await RunnerFixture()
        let commit = try await fx.commit(["AGENTS.md": "version one\n"])
        let id = try await fx.approvedThread()
        try await fx.commit(["AGENTS.md": "version two\n"])

        _ = try await fx.runner(id).run(fx.options())
        let prompt = try fx.prompt(id, turn: 1)
        #expect(prompt.contains("version one"))
        #expect(!prompt.contains("version two"))
        let worktree = WorktreeManager(repoRoot: fx.repo, git: fx.git).path(for: id)
        let cutFrom = try await fx.git.run(["rev-parse", "HEAD"], in: worktree).stdout
        #expect(cutFrom.trimmingCharacters(in: .whitespacesAndNewlines) == commit)
    }

    @Test(arguments: ["main checkout", "worktree edit", "worktree commit"])
    func aLaterEditDoesNotChangeThePromptOfATurnBuiltFromTheGoal(edit: String) async throws {
        let fx = try await RunnerFixture()
        try await fx.commit(["AGENTS.md": "version one\n"])
        let id = try await fx.approvedThread()
        let failed = try await fx.runner(id).run(fx.options("exit=2"))
        #expect(failed.result == .failed)

        let worktree = WorktreeManager(repoRoot: fx.repo, git: fx.git).path(for: id)
        switch edit {
        case "main checkout":
            try await fx.commit(["AGENTS.md": "version two\n"])
            try "version three\n".write(
                to: fx.repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        case "worktree edit":
            try "version two\n".write(
                to: worktree.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        default:
            try await fx.commit(["AGENTS.md": "version two\n"], in: worktree)
        }

        let again = try await fx.runner(id).run(fx.options())
        #expect(again.result == .succeeded)
        let prompt = try fx.prompt(id, turn: again.turn)
        #expect(prompt == (try fx.prompt(id, turn: 1)))
        #expect(prompt.contains("version one"))
        #expect(!prompt.contains("version two") && !prompt.contains("version three"))
        let hashes = try fx.starts(id).map { $0.data["instructions"]?["sha256"]?.stringValue }
        #expect(Set(hashes) == [sha256("version one")])
    }

    @Test func aThreadWithoutARecordedCommitFallsBackToWhereItsBranchLeftTheBase() async throws {
        let fx = try await RunnerFixture()
        try await fx.commit(["AGENTS.md": "version one\n"])
        let id = try await fx.approvedThread()
        // A log written before `base_commit` existed.
        let log = fx.project.eventsURL(id)
        let old = try String(contentsOf: log, encoding: .utf8)
        #expect(old.contains("\"base_commit\":\""))
        try old.replacingOccurrences(
            of: #""base_commit":"[0-9a-f]+""#, with: "\"base_commit\":null", options: .regularExpression
        ).write(to: log, atomically: true, encoding: .utf8)

        _ = try await fx.runner(id).run(fx.options("exit=2"))
        try await fx.commit(["AGENTS.md": "version two\n"])
        let again = try await fx.runner(id).run(fx.options())
        let prompt = try fx.prompt(id, turn: again.turn)
        #expect(prompt.contains("version one"))
        #expect(!prompt.contains("version two"))
    }
}
