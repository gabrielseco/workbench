import Foundation
import Testing

@testable import WorkbenchCore

/// A chat may read the repository (docs/plan/P22-chat-feed.md, "Chat reads the repository"): what the agent is given and what the
/// chat leaves behind.
@Suite(.processGate) struct ChatRepoTests {
    private func chat(_ d: Drafting, environment: [String: String]? = nil) async throws -> ChatResult {
        try await d.fx.service.chat(
            target: .newThread(name: "idea"), message: "how does it work?", config: d.config,
            environment: environment ?? d.environment, timeout: 30)
    }

    private func seen(_ dump: URL) throws -> (argv: String, files: [String]) {
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as? [String: Any])
        return (try #require(json["argv"] as? [String]).joined(separator: "\n"), json["cwd_files"] as? [String] ?? [])
    }

    @Test func aClaudeChatMayReadReadGrepAndGlobInAFolderThatHoldsTheRepositoryCopy() async throws {
        let d = try await drafting(provider: .claude, allowUnpriced: false)
        let answer = try d.file("answer.txt", "It starts in a.txt.")
        let dump = d.dir.appendingPathComponent("dump.json")
        let result = try await chat(d, environment: d.claudeEnvironment("answer=\(answer)", "dump=\(dump.path)"))
        #expect(result.end == "ok")
        let run = try seen(dump)
        #expect(run.argv.contains("--tools\nRead\nGrep\nGlob\n--allowedTools\nRead\nGrep\nGlob"), "\(run.argv)")
        let reachesOut = ["Bash", "Edit", "Write", "Web"].contains { run.argv.contains($0) }
        #expect(!reachesOut, "nothing that writes, runs or reaches out")
        #expect(run.files == [RepoSnapshot.folderName], "the folder it ran in holds the copy")
    }

    @Test func withTheKeyOffAChatSeesNoRepositoryAndHasNoTools() async throws {
        var d = try await drafting(provider: .claude, allowUnpriced: false)
        d.config.chatReadsRepo = false
        let answer = try d.file("answer.txt", "Say more.")
        let dump = d.dir.appendingPathComponent("dump.json")
        _ = try await chat(d, environment: d.claudeEnvironment("answer=\(answer)", "dump=\(dump.path)"))
        let run = try seen(dump)
        #expect(!run.argv.contains("Grep") && !run.argv.contains("Read"), "\(run.argv)")
        #expect(run.files.isEmpty, "an empty folder, as before")
    }

    @Test func theCopyIsRemovedWithTheTurnAndCostsTheRepositoryNothing() async throws {
        let d = try await drafting()
        let branches = try await d.branches()
        let before = try await d.fx.git.run(["status", "--porcelain", "--ignored"], in: d.fx.repo).stdout
        let result = try await chat(d)
        #expect(result.end == "ok")
        let scratch = d.fx.service.chatScratch(result.id)
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "the folder and the copy are gone")
        #expect(try await d.branches() == branches, "no branch")
        #expect(try await d.fx.git.run(["status", "--porcelain", "--ignored"], in: d.fx.repo).stdout == before)
        #expect(try await d.fx.git.run(["worktree", "list"], in: d.fx.repo).stdout.split(separator: "\n").count == 1)
    }

    @Test func aRepositoryThatCannotBeCopiedStillGetsAChat() async throws {
        var d = try await drafting(provider: .claude, allowUnpriced: false)
        // A base the repository does not have: no copy, so no tools, and the turn goes on as it did.
        d.config.chatReadsRepo = true
        let answer = try d.file("answer.txt", "Fine.")
        let dump = d.dir.appendingPathComponent("dump.json")
        _ = try await d.fx.git.run(["checkout", "-q", "--orphan", "empty"], in: d.fx.repo)
        _ = try await d.fx.git.run(["rm", "-rf", "-q", "--cached", "."], in: d.fx.repo)
        for name in ["main", "master"] { _ = try await d.fx.git.run(["branch", "-q", "-D", name], in: d.fx.repo) }
        let result = try await chat(d, environment: d.claudeEnvironment("answer=\(answer)", "dump=\(dump.path)"))
        #expect(result.end == "ok" && result.reply == "Fine.")
        #expect(try !seen(dump).argv.contains("Grep"))
    }
}
