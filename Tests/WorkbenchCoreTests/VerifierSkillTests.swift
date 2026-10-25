import Crypto
import Foundation
import Testing

@testable import WorkbenchCore

/// A scratch repository whose commits we control, for reading a skill out of a commit.
private struct SkillRepo {
    let root: URL
    let git: GitRunner

    init() async throws {
        let dir = Scratch.url("skill")
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
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    @discardableResult
    func commit() async throws -> String {
        _ = try await git.run(["add", "-A"], in: root)
        let result = try await git.run(["commit", "-q", "-m", "c", "--allow-empty"], in: root)
        #expect(result.succeeded, "\(result.stderr)")
        return try await git.run(["rev-parse", "HEAD"], in: root).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load(_ commit: String, _ path: String) async -> Result<VerifierSkill, VerifierSkill.Problem> {
        await VerifierSkill.load(git: git, repo: root, commit: commit, path: path)
    }
}

private func skill(_ result: Result<VerifierSkill, VerifierSkill.Problem>) throws -> VerifierSkill {
    try result.get()
}

private func problem(_ result: Result<VerifierSkill, VerifierSkill.Problem>) -> VerifierSkill.Problem? {
    if case .failure(let problem) = result { problem } else { nil }
}

@Suite(.processGate) struct VerifierSkillTests {
    @Test(arguments: [".claude/skills/verify/SKILL.md", ".agents/skills/verify/SKILL.md"])
    func aSkillUnderEitherDirectoryIsRead(path: String) async throws {
        let repo = try await SkillRepo()
        try repo.write(path, "# Verify\n\nBuild the app.\n")
        let commit = try await repo.commit()

        let found = try skill(await repo.load(commit, path))
        #expect(found.path == path)
        #expect(found.text == "# Verify\n\nBuild the app.")
        #expect(found.bytes == found.text.utf8.count)
        #expect(!found.truncated)
        let digest = SHA256.hash(data: Data(found.text.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(found.sha256 == digest)
    }

    @Test func nothingIsDiscoveredWhenThePathIsOtherwise() async throws {
        let repo = try await SkillRepo()
        try repo.write(".claude/skills/verify/SKILL.md", "claude\n")
        try repo.write(".agents/skills/verify/SKILL.md", "agents\n")
        let commit = try await repo.commit()

        #expect(try skill(await repo.load(commit, ".agents/skills/verify/SKILL.md")).text == "agents")
        #expect(problem(await repo.load(commit, "skills/verify/SKILL.md")) == .missing("skills/verify/SKILL.md"))
    }

    @Test func theBaseCommitIsReadNotTheEditedWorktree() async throws {
        let repo = try await SkillRepo()
        let path = ".claude/skills/verify/SKILL.md"
        try repo.write(path, "original\n")
        let base = try await repo.commit()
        try repo.write(path, "edited by the coding run\n")
        let later = try await repo.commit()
        try repo.write(path, "edited and not committed\n")

        #expect(try skill(await repo.load(base, path)).text == "original")
        #expect(try skill(await repo.load(later, path)).text == "edited by the coding run")
    }

    @Test func aSkillOverTheLimitIsCutWithAMarker() async throws {
        let repo = try await SkillRepo()
        let path = "SKILL.md"
        let lines = (0..<4000).map { "line \($0) of the skill" }.joined(separator: "\n")
        try repo.write(path, lines + "\n")
        let commit = try await repo.commit()

        let found = try skill(await repo.load(commit, path))
        #expect(found.truncated)
        #expect(found.bytes <= VerifierSkill.sizeLimit)
        #expect(found.text.hasSuffix(VerifierSkill.truncationMarker))
        #expect(found.text.hasPrefix("line 0 of the skill\n"))
        #expect(found.bytes == found.text.utf8.count)
    }

    @Test func aBlobCutByTheReaderIsMarkedEvenWhenTheRestIsWhitespace() async throws {
        let repo = try await SkillRepo()
        let padding = String(repeating: " ", count: ProjectInstructions.blobReadLimit)
        try repo.write("SKILL.md", "# Verify\n" + padding + "the instructions that matter\n")
        let commit = try await repo.commit()

        let found = try skill(await repo.load(commit, "SKILL.md"))
        #expect(found.truncated)
        #expect(found.text == "# Verify\n" + VerifierSkill.truncationMarker)
        #expect(!found.text.contains("the instructions that matter"))
    }

    @Test func aSkillExactlyAtTheLimitIsNotCut() {
        let text = String(repeating: "a", count: VerifierSkill.sizeLimit)
        let found = try? skill(VerifierSkill.finish(path: "s.md", raw: text))
        #expect(found?.truncated == false)
        #expect(found?.bytes == VerifierSkill.sizeLimit)
    }

    @Test func aMissingSkillIsRefusedWithThePath() async throws {
        let repo = try await SkillRepo()
        let commit = try await repo.commit()
        let refused = problem(await repo.load(commit, ".claude/skills/verify/SKILL.md"))
        #expect(refused == .missing(".claude/skills/verify/SKILL.md"))
        #expect(refused?.description.contains(".claude/skills/verify/SKILL.md") == true)
    }

    @Test func aSkillAddedOnlyInTheWorktreeIsMissingAtTheBase() async throws {
        let repo = try await SkillRepo()
        let base = try await repo.commit()
        try repo.write("SKILL.md", "added by the run\n")
        #expect(problem(await repo.load(base, "SKILL.md")) == .missing("SKILL.md"))
    }

    @Test(arguments: ["", "\n", "  \n\t\n", "\u{FEFF}\r\n"])
    func anEmptySkillIsRefused(content: String) async throws {
        let repo = try await SkillRepo()
        try repo.write("SKILL.md", content)
        let commit = try await repo.commit()
        #expect(problem(await repo.load(commit, "SKILL.md")) == .empty("SKILL.md"))
    }

    @Test func aDirectoryIsNotASkill() async throws {
        let repo = try await SkillRepo()
        try repo.write("skills/verify/SKILL.md", "x\n")
        let commit = try await repo.commit()
        #expect(problem(await repo.load(commit, "skills/verify")) == .missing("skills/verify"))
    }

    @Test func aSymlinkIsRefusedWithTheRealPathToUse() async throws {
        let repo = try await SkillRepo()
        try repo.write(".agents/skills/verify/SKILL.md", "the real one\n")
        try repo.symlink(".claude/SKILL.md", to: "../.agents/skills/verify/SKILL.md")
        let commit = try await repo.commit()

        let refused = problem(await repo.load(commit, ".claude/SKILL.md"))
        #expect(
            refused == .symlink(".claude/SKILL.md", link: ".claude/SKILL.md", real: ".agents/skills/verify/SKILL.md"))
        let message = refused?.description ?? ""
        #expect(message.contains("is the symlink .claude/SKILL.md"), "\(message)")
        #expect(message.hasSuffix(": .agents/skills/verify/SKILL.md"), "\(message)")
    }

    @Test func aSkillBehindASymlinkedDirectoryIsRefusedWithTheRealPath() async throws {
        let repo = try await SkillRepo()
        try repo.write(".agents/skills/verify/SKILL.md", "the real one\n")
        try repo.symlink(".claude/skills/verify", to: "../../.agents/skills/verify")
        let commit = try await repo.commit()

        let path = ".claude/skills/verify/SKILL.md"
        let refused = problem(await repo.load(commit, path))
        #expect(refused == .symlink(path, link: ".claude/skills/verify", real: ".agents/skills/verify/SKILL.md"))
        #expect(refused?.description.contains("goes through the symlink .claude/skills/verify") == true)
    }

    @Test func aSymlinkOutOfTheRepositoryNamesNoPath() async throws {
        let repo = try await SkillRepo()
        try repo.symlink("SKILL.md", to: "/etc/hosts")
        try repo.symlink("UP.md", to: "../../elsewhere.md")
        let commit = try await repo.commit()

        #expect(problem(await repo.load(commit, "SKILL.md")) == .symlink("SKILL.md", link: "SKILL.md", real: ""))
        #expect(problem(await repo.load(commit, "UP.md")) == .symlink("UP.md", link: "UP.md", real: ""))
        #expect(problem(await repo.load(commit, "SKILL.md"))?.description.hasSuffix("the real file") == true)
    }

    @Test func aSkillOverTheBlobCeilingIsRefused() async throws {
        let repo = try await SkillRepo()
        try repo.write("SKILL.md", String(repeating: "x\n", count: ProjectInstructions.blobSizeCeiling))
        let commit = try await repo.commit()
        #expect(problem(await repo.load(commit, "SKILL.md")) == .tooLarge("SKILL.md"))
    }

    @Test func windowsLineEndingsAndABOMAreNormalised() async throws {
        let repo = try await SkillRepo()
        try repo.write("SKILL.md", "\u{FEFF}one\r\ntwo\r\n")
        let commit = try await repo.commit()
        #expect(try skill(await repo.load(commit, "SKILL.md")).text == "one\ntwo")
    }

    @Test func theInstructionsReaderStillSkipsASymlink() async throws {
        let repo = try await SkillRepo()
        try repo.write("real.md", "real\n")
        try repo.symlink("AGENTS.md", to: "real.md")
        let commit = try await repo.commit()
        let instructions = await ProjectInstructions.load(git: repo.git, repo: repo.root, commit: commit)
        #expect(instructions == nil)
    }
}
