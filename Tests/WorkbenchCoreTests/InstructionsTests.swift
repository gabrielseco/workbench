import CryptoKit
import Foundation
import Testing

@testable import WorkbenchCore

/// A scratch repository whose commits we control, for reading instructions out of a commit.
private struct InstructionsRepo {
    let root: URL
    let git: GitRunner

    init() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-instr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir.resolvingSymlinksInPath()
        git = try isolatedGit()
        _ = try await git.run(["init", "-q", "-b", "main"], in: root)
        try write("README.md", "hi\n")
    }

    func write(_ name: String, _ content: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func symlink(_ name: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
    }

    @discardableResult
    func commit() async throws -> String {
        _ = try await git.run(["add", "-A"], in: root)
        let result = try await git.run(["commit", "-q", "-m", "c", "--allow-empty"], in: root)
        #expect(result.succeeded, "\(result.stderr)")
        return try await git.run(["rev-parse", "HEAD"], in: root).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load(_ commit: String) async -> ProjectInstructions? {
        await ProjectInstructions.load(git: git, repo: root, commit: commit)
    }
}

@Suite(.processGate) struct ProjectInstructionsTests {
    @Test func replacedImportPathsDoNotConsumeTheSizeLimit() async throws {
        let repo = try await InstructionsRepo()
        let prefix = String(repeating: "./", count: 150)
        let count = ProjectInstructions.maxImports
        let content = String(repeating: "x", count: 300)
        try repo.write("AGENTS.md", (0..<count).map { "@\(prefix)f\($0).md" }.joined(separator: "\n"))
        for i in 0..<count { try repo.write("f\(i).md", content) }
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(loaded.skipped.isEmpty)
        #expect(loaded.text == Array(repeating: content, count: count).joined(separator: "\n"))
        #expect(!loaded.truncated)
    }

    @Test func agentsFileIsUsedAndHashed() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("AGENTS.md", "# Rules\n\nBe kind.\n")
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(loaded.file == "AGENTS.md")
        #expect(loaded.text == "# Rules\n\nBe kind.")
        #expect(loaded.bytes == loaded.text.utf8.count)
        let expected = SHA256.hash(data: Data(loaded.text.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(loaded.sha256 == expected)
        #expect(!loaded.truncated)
        #expect(loaded.skipped.isEmpty)
    }

    @Test func claudeMdIsTheFallbackOnly() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("CLAUDE.md", "claude rules\n")
        #expect(try await repo.load(try await repo.commit())?.file == "CLAUDE.md")

        try repo.write("AGENTS.md", "agents rules\n")
        let both = try #require(await repo.load(try await repo.commit()))
        #expect(both.file == "AGENTS.md")
        #expect(both.text == "agents rules")
    }

    @Test func neitherFileMeansNothing() async throws {
        let repo = try await InstructionsRepo()
        #expect(await repo.load(try await repo.commit()) == nil)
    }

    @Test func importsInsideTheRepositoryAreExpanded() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("AGENTS.md", "top\n@docs/a.md\nbottom\n")
        try repo.write("docs/a.md", "from a\n@b.md\n")  // relative to docs/
        try repo.write("docs/b.md", "from b\n")
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(loaded.text == "top\nfrom a\nfrom b\nbottom")
        #expect(loaded.skipped.isEmpty)
    }

    @Test func unsafeOrUnusableImportsStayLiteralAndAreListed() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("outside.txt", "secret\n")
        try repo.write("AGENTS.md", "@/etc/passwd\n@../x.md\n@missing.md\n@link.md\n@dir\n@self.md\n@AGENTS.md\nend\n")
        try repo.write("self.md", "self\n@self.md\n")
        try repo.write("dir/f.md", "f\n")
        try repo.symlink("link.md", to: "outside.txt")
        let loaded = try #require(await repo.load(try await repo.commit()))

        #expect(loaded.text.contains("@/etc/passwd"))
        #expect(loaded.text.contains("@../x.md"))
        #expect(loaded.text.contains("@missing.md"))
        #expect(loaded.text.contains("@link.md"))
        #expect(loaded.text.contains("@dir"))
        #expect(!loaded.text.contains("secret"))
        #expect(loaded.text.contains("self\n@self.md"), "the second inclusion is left literal")
        let reasons = loaded.skipped.joined(separator: "\n")
        for name in ["/etc/passwd", "../x.md", "missing.md", "link.md", "dir", "self.md", "AGENTS.md"] {
            #expect(reasons.contains(name), "\(name) not listed in \(reasons)")
        }
    }

    @Test func importDepthIsLimitedToThree() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("AGENTS.md", "@1.md\n")
        try repo.write("1.md", "one\n@2.md\n")
        try repo.write("2.md", "two\n@3.md\n")
        try repo.write("3.md", "three\n@4.md\n")
        try repo.write("4.md", "four\n")
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(loaded.text == "one\ntwo\nthree\n@4.md")
        #expect(loaded.skipped.contains { $0.hasPrefix("4.md") })
    }

    @Test func importsInsideCodeFencesAreNotExpanded() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("AGENTS.md", "```\n@a.md\n```\n@a.md\n")
        try repo.write("a.md", "A\n")
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(loaded.text == "```\n@a.md\n```\nA")
    }

    @Test func aLongerFenceIsNotClosedByAShorterOne() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("AGENTS.md", "````\n```\n@a.md\n```\n@b.md\n````\n@c.md\n")
        try repo.write("a.md", "A\n")
        try repo.write("b.md", "B\n")
        try repo.write("c.md", "C\n")
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(loaded.text == "````\n```\n@a.md\n```\n@b.md\n````\nC")
    }

    @Test func fencedImportsAreListedAsSkipped() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("AGENTS.md", "~~~\n@a.md\n~~~\n")
        try repo.write("a.md", "A\n")
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(loaded.skipped == ["a.md: inside a code block"])
    }

    @Test func onlyAnExactImportLineIsExpanded() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("AGENTS.md", "    @a.md\n@a.md \n- @a.md\n@a.md\n")
        try repo.write("a.md", "A\n")
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(loaded.text == "    @a.md\n@a.md \n- @a.md\nA")
    }

    @Test func importsAreBoundedInNumber() async throws {
        let repo = try await InstructionsRepo()
        let count = ProjectInstructions.maxImports + 3
        try repo.write("AGENTS.md", (0..<count).map { "@f\($0).md" }.joined(separator: "\n") + "\n")
        for i in 0..<count { try repo.write("f\(i).md", "file \(i)\n") }
        let loaded = try #require(await repo.load(try await repo.commit()))
        let expanded = loaded.text.split(separator: "\n").filter { $0.hasPrefix("file ") }
        #expect(expanded.count == ProjectInstructions.maxImports)
        #expect(loaded.skipped.count == 3)
        #expect(loaded.text.hasSuffix("@f\(count - 1).md"))
    }

    @Test func importsStopBeingFetchedOncePastTheSizeLimit() async throws {
        let repo = try await InstructionsRepo()
        let filler = String(repeating: "x", count: 99) + "\n"
        try repo.write("AGENTS.md", String(repeating: filler, count: 200) + "@a.md\n")
        try repo.write("a.md", "A\n")
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(!loaded.text.contains("\nA\n"))
        #expect(loaded.skipped == ["a.md: past the size limit"])
    }

    @Test func aBlobOverTheCeilingIsNeverRead() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("AGENTS.md", String(repeating: "y\n", count: ProjectInstructions.blobSizeCeiling))
        try repo.write("CLAUDE.md", "small\n")
        // Too large to read, so it counts as absent and the fallback applies.
        #expect(try await repo.load(try await repo.commit())?.file == "CLAUDE.md")
    }

    @Test func aSymlinkedInstructionsFileCountsAsAbsent() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("real.md", "real\n")
        try repo.symlink("AGENTS.md", to: "real.md")
        try repo.write("CLAUDE.md", "claude\n")
        #expect(try await repo.load(try await repo.commit())?.file == "CLAUDE.md")
    }

    @Test func oversizedTextIsCutAtALineBoundaryWithAMarker() async throws {
        let repo = try await InstructionsRepo()
        // Two-byte characters, so the byte limit falls inside one.
        let line = String(repeating: "é", count: 99)  // 198 bytes
        let body = (0..<200).map { _ in line }.joined(separator: "\n")
        try repo.write("AGENTS.md", body + "\n")
        let loaded = try #require(await repo.load(try await repo.commit()))

        #expect(loaded.truncated)
        #expect(loaded.bytes <= ProjectInstructions.sizeLimit)
        #expect(loaded.text.hasSuffix("\n" + ProjectInstructions.truncationMarker))
        let kept = loaded.text.dropLast(ProjectInstructions.truncationMarker.count + 1)
        #expect(kept.split(separator: "\n").allSatisfy { $0 == Substring(line) }, "only whole lines are kept")
    }

    @Test func encodingIsNormalized() async throws {
        let repo = try await InstructionsRepo()
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("one\r\ntwo\r\n".utf8))
        data.append(Data([0xFF]))  // invalid UTF-8
        try data.write(to: repo.root.appendingPathComponent("AGENTS.md"))
        let loaded = try #require(await repo.load(try await repo.commit()))
        #expect(loaded.text.hasPrefix("one\ntwo\n"))
        #expect(!loaded.text.contains("\r"))
        #expect(!loaded.text.hasPrefix("\u{FEFF}"))
    }

    @Test func theCommitIsTheOnlySource() async throws {
        let repo = try await InstructionsRepo()
        try repo.write("AGENTS.md", "committed\n")
        let commit = try await repo.commit()
        try repo.write("AGENTS.md", "edited after\n")
        #expect(try await repo.load(commit)?.text == "committed")
        _ = try await repo.git.run(["commit", "-qam", "later"], in: repo.root)
        #expect(try await repo.load(commit)?.text == "committed")
    }
}

@Suite(.processGate) struct InstructionsInPromptTests {
    private func fixture(config: String = "", agents: String? = "Always run the checks.\n") async throws
        -> (RunnerFixture, String) {
        let fx = try await RunnerFixture(extraConfig: config)
        if let agents {
            try agents.write(to: fx.repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
            _ = try await fx.git.run(["add", "-A"], in: fx.repo)
            _ = try await fx.git.run(["commit", "-q", "-m", "instructions"], in: fx.repo)
        }
        return (fx, try await fx.approvedThread())
    }

    private func prompt(_ fx: RunnerFixture, _ id: String, turn: Int) throws -> String {
        try String(contentsOf: fx.project.promptURL(id, turn: turn), encoding: .utf8)
    }

    private func startedEvents(_ fx: RunnerFixture, _ id: String) throws -> [Event] {
        try fx.events(id).filter { $0.kind == .turnStarted }
    }

    @Test func sectionSitsBetweenOutOfScopeAndChecks() async throws {
        let (fx, id) = try await fixture(config: "check_command = \"scripts/check.sh\"")
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let text = try prompt(fx, id, turn: 1)

        let scope = try #require(text.range(of: "## Out of scope"))
        let section = try #require(text.range(of: "## Project instructions"))
        let checks = try #require(text.range(of: "## Checking your work"))
        #expect(scope.upperBound < section.lowerBound)
        #expect(section.upperBound < checks.lowerBound)
        #expect(
            text.contains(
                "These are the project's instructions for anyone working in this repository. Where they "
                    + "describe pushing, opening or merging pull requests, Workbench does that after your work "
                    + "is reviewed: commit in this worktree and stop there."))
        #expect(text.contains("Always run the checks."))
    }

    @Test func turnStartedRecordsWhatWasSent() async throws {
        let (fx, id) = try await fixture()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let started = try #require(try startedEvents(fx, id).first)
        let info = try #require(started.data["instructions"])
        #expect(info["file"]?.stringValue == "AGENTS.md")
        #expect(info["bytes"]?.intValue == "Always run the checks.".utf8.count)
        #expect(info["sha256"]?.stringValue?.count == 64)
        #expect(info["truncated"] == false)
        #expect(info["skipped"] == [])
    }

    @Test func noFileMeansNoSectionAndNull() async throws {
        let (fx, id) = try await fixture(agents: nil)
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        #expect(!(try prompt(fx, id, turn: 1)).contains("## Project instructions"))
        let started = try #require(try startedEvents(fx, id).first)
        #expect(started.data["instructions"] == .null)
    }

    @Test func optOutRemovesTheSection() async throws {
        let (fx, id) = try await fixture(config: "project_instructions = false")
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        #expect(!(try prompt(fx, id, turn: 1)).contains("## Project instructions"))
        #expect(try startedEvents(fx, id).first?.data["instructions"] == .null)
    }

    @Test func aFeedbackTurnDoesNotRepeatIt() async throws {
        let (fx, id) = try await fixture()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        _ = try await fx.runner(id).run(fx.options("stream-events=1", feedback: "Make it louder."))
        #expect(!(try prompt(fx, id, turn: 2)).contains("## Project instructions"))
        let second = try startedEvents(fx, id)[1]
        #expect(second.data["instructions"] == nil)
    }

    @Test func aFailedFirstTurnGetsItAgainOnRetry() async throws {
        let (fx, id) = try await fixture()
        let first = try await fx.runner(id).run(fx.options("exit=2"))
        #expect(first.result == .failed)
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        #expect(try prompt(fx, id, turn: 2).contains("Always run the checks."))
        #expect(try startedEvents(fx, id)[1].data["instructions"]?["file"]?.stringValue == "AGENTS.md")
    }

    @Test func editsAfterTheWorktreeWasCutDoNotReachALaterPrompt() async throws {
        let (fx, id) = try await fixture()
        _ = try await fx.runner(id).run(fx.options("exit=2"))  // cuts the worktree, turn fails

        // The main checkout changes, and the run edited and committed the file in its worktree.
        try "main checkout edit\n".write(
            to: fx.repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "run edit\n".write(
            to: worktree.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["commit", "-qam", "run commit"], in: worktree)
        try "uncommitted run edit\n".write(
            to: worktree.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let text = try prompt(fx, id, turn: 2)
        #expect(text.contains("Always run the checks."))
        #expect(!text.contains("edit"))
    }

    @Test func theBaseCommitIsRecordedWhenTheWorktreeIsCut() async throws {
        let (fx, id) = try await fixture()
        _ = try await fx.runner(id).run(fx.options("stream-events=1"))
        let created = try #require(try fx.events(id).first { $0.kind == .worktreeCreated })
        let head = try await fx.git.run(["rev-parse", "main"], in: fx.repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(created.data["base_commit"]?.stringValue == head)
    }
}

@Suite(.processGate) struct ProjectInstructionsConfigTests {
    @Test func defaultsToOnAndAcceptsABoolean() throws {
        let tools = "\n[tools]\navailable = [\"Read\"]\n"
        #expect(try Config.parse(tools).projectInstructions == true)
        #expect(try Config.parse("project_instructions = false\n" + tools).projectInstructions == false)
    }

    @Test func aNonBooleanIsALineNumberedError() {
        do {
            _ = try Config.parse("\nproject_instructions = \"no\"\n\n[tools]\navailable = [\"Read\"]\n")
            Issue.record("expected an error")
        } catch let error as ConfigError {
            let problem = error.problems.first
            #expect(problem?.line == 2)
            #expect(problem?.message.contains("project_instructions") == true)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
