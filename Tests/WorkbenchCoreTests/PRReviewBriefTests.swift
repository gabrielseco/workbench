import Foundation
import Testing

@testable import WorkbenchCore

/// What goes into the brief: the checklist, the instructions, the pinned base and the diff.
@Suite(.processGate) struct PRReviewBriefTests {
    // MARK: the checklist and the project instructions

    @Test func theChecklistIsReadFromThePullRequestsHeadAndAMissingOneIsSaidNotSilent() async throws {
        let r = try await reviewedPR(extraConfig: "[pr_review]\nchecklist = \"docs/REVIEW.md\"\n")
        let worktree = r.fx.project.worktreesDirectory.appendingPathComponent(r.id)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "- never block\n".write(to: worktree.appendingPathComponent("docs/REVIEW.md"), atomically: true, encoding: .utf8)
        _ = try await r.fx.git.run(["add", "-A"], in: worktree)
        _ = try await r.fx.git.run(["commit", "-q", "-m", "docs: checklist"], in: worktree)
        let head = try await shipOut(["rev-parse", "HEAD"], worktree, r.fx)
        _ = try await r.fx.git.run(["push", "-q", "origin", "HEAD:refs/heads/workbench/\(r.id)"], in: worktree)

        let result = try await r.round()
        #expect(result.warnings.isEmpty)
        #expect(r.codex.read("brief_1")?.contains("- never block") == true)

        let other = try await reviewedPR(extraConfig: "[pr_review]\nchecklist = \"docs/NOPE.md\"\n")
        let missing = try await other.round()
        #expect(missing.verdict == .clean, "a missing checklist does not fail the round")
        #expect(missing.warnings.first?.contains("docs/NOPE.md") == true)
    }

    @Test func aFileTheStageNamesIsReadFromTheHeadAndAMissingOneFailsTheRound() async throws {
        let table = "[review.stage.pr-review]\ninputs = [\"diff\", \"goal\", \"docs/DESIGN.md\"]\n"
        let r = try await reviewedPR(extraConfig: table)
        let worktree = r.fx.project.worktreesDirectory.appendingPathComponent(r.id)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "Design rule: dark first\n".write(
            to: worktree.appendingPathComponent("docs/DESIGN.md"), atomically: true, encoding: .utf8)
        _ = try await r.fx.git.run(["add", "-A"], in: worktree)
        _ = try await r.fx.git.run(["commit", "-q", "-m", "docs: design"], in: worktree)
        _ = try await r.fx.git.run(["push", "-q", "origin", "HEAD:refs/heads/workbench/\(r.id)"], in: worktree)

        let result = try await r.round()
        #expect(result.verdict == .clean, "\(result.failure ?? "")")
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("## File: docs/DESIGN.md") && brief.contains("Design rule: dark first"), "\(brief)")

        let other = try await reviewedPR(extraConfig: table)
        let missing = try await other.round()
        #expect(missing.verdict == nil, "a stage that cannot read its input must not pass")
        #expect(missing.failure?.contains("docs/DESIGN.md") == true, "\(missing.failure ?? "")")
        #expect(other.codex.runs == 0, "Codex is not started without the file")
    }

    @Test func aGoalOrChecklistPastTheLimitSaysSoInsteadOfBeingCutQuietly() async throws {
        let r = try await reviewedPR(extraConfig: "[pr_review]\nchecklist = \"docs/REVIEW.md\"\n")
        let goalURL = r.fx.project.goalURL(r.id)
        let long = String(repeating: "padding line\n", count: 4000)
        try (try String(contentsOf: goalURL, encoding: .utf8) + long + "- [ ] LAST CRITERION\n")
            .write(to: goalURL, atomically: true, encoding: .utf8)
        let worktree = r.fx.project.worktreesDirectory.appendingPathComponent(r.id)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try (long + "LAST RULE\n").write(to: worktree.appendingPathComponent("docs/REVIEW.md"), atomically: true, encoding: .utf8)
        _ = try await r.fx.git.run(["add", "-A"], in: worktree)
        _ = try await r.fx.git.run(["commit", "-q", "-m", "docs: checklist"], in: worktree)
        _ = try await r.fx.git.run(["push", "-q", "origin", "HEAD:refs/heads/workbench/\(r.id)"], in: worktree)

        _ = try await r.round()
        let brief = try #require(r.codex.read("brief_1"))
        #expect(!brief.contains("LAST CRITERION") && !brief.contains("LAST RULE"), "cut at the limit")
        #expect(brief.contains("[cut here at 32 KiB: the rest is at \(goalURL.path)]"), "the goal's cut is announced")
        #expect(brief.contains("[cut here at 32 KiB: the rest is at docs/REVIEW.md in the checkout]"))
        #expect(ThreadService.bounded("short", limit: 10, rest: "x") == "short")
    }

    @Test func aChecklistThatIsASymlinkOutOfTheTreeIsNotRead() throws {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString)")
        try "top secret".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("REVIEW.md"), withDestinationURL: secret)
        #expect(ThreadService.readChecklist("REVIEW.md", in: tree) == nil)
        try "fine".write(to: tree.appendingPathComponent("OK.md"), atomically: true, encoding: .utf8)
        #expect(ThreadService.readChecklist("OK.md", in: tree) == "fine")
        #expect(ThreadService.readChecklist("missing.md", in: tree) == nil)
    }

    @Test func theProjectInstructionsAtTheBaseGoIntoTheBriefUnlessTurnedOff() async throws {
        let r = try await reviewedPR()
        try "# Rules\nNo blocking waits.\n".write(
            to: r.fx.repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        _ = try await r.fx.git.run(["add", "-A"], in: r.fx.repo)
        _ = try await r.fx.git.run(["commit", "-q", "-m", "docs: agents"], in: r.fx.repo)
        _ = try await r.fx.git.run(["push", "-q", "origin", "main"], in: r.fx.repo)
        _ = try await r.fx.git.run(["fetch", "-q", "origin"], in: r.fx.repo)

        _ = try await r.round()
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("No blocking waits."), "AGENTS.md at origin/main is in the brief")
        let diff = try #require(r.codex.read("diff_1"))
        #expect(diff.contains("+hello") && !diff.contains("+# Rules"), "the diff is the pull request's, not the base's")

        var off = r
        off.config.projectInstructions = false
        _ = try await off.round(again: true)
        #expect(off.codex.read("brief_2")?.contains("No blocking waits.") == false)
    }

    @Test func theBaseIsFetchedSoAStaleOriginTrackingRefDoesNotChangeWhatIsReviewed() async throws {
        let r = try await reviewedPR()
        let git = r.fx.git
        let repo = r.fx.repo
        _ = try await git.run(["push", "-q", "origin", "main"], in: repo)
        _ = try await git.run(["fetch", "-q", "origin"], in: repo)
        let stale = try await shipOut(["rev-parse", "origin/main"], repo, r.fx)
        try "# Rules\nNewer rules.\n".write(to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "-A"], in: repo)
        _ = try await git.run(["commit", "-q", "-m", "docs: agents"], in: repo)
        _ = try await git.run(["push", "-q", "origin", "main"], in: repo)
        _ = try await git.run(["update-ref", "refs/remotes/origin/main", stale], in: repo)

        _ = try await r.round()
        #expect(r.codex.read("brief_1")?.contains("Newer rules.") == true, "the base was fetched, not read from the stale ref")
    }

    @Test func aShippedThreadWhoseWorktreeIsGoneCanStillBeReviewed() async throws {
        let r = try await reviewedPR()
        _ = try await r.fx.git.run(
            ["worktree", "remove", "--force", r.fx.project.worktreesDirectory.appendingPathComponent(r.id).path], in: r.fx.repo)
        let result = try await r.round()
        #expect(result.verdict == .clean)
        #expect(r.codex.read("diff_1")?.contains("+hello") == true, "the diff came from the commits, not the worktree")
    }
}
