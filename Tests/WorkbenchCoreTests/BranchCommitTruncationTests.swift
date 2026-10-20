import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct BranchCommitTruncationTests {
    @Test func aListingGitRunnerCutIsNotPublishedAsWhole() async throws {
        let fx = try await RunnerFixture()
        // One commit whose subject line is longer than the runner's output limit: git succeeds, the captured text is cut.
        let message = fx.repo.appendingPathComponent("long-message.txt")
        try String(repeating: "x", count: GitRunner.outputLimit + 1000).write(to: message, atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["commit", "-q", "--allow-empty", "-m", "first"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "--allow-empty", "-F", message.path], in: fx.repo)

        #expect(await BranchCommit.oldest(in: "HEAD~1..HEAD", at: fx.repo, git: fx.git) == nil)
        // A normal range still lists.
        let listed = await BranchCommit.oldest(in: "HEAD~2..HEAD~1", at: fx.repo, git: fx.git)
        #expect(listed?.count == 1 && listed?.commits.first?.subject == "first")
    }
}
