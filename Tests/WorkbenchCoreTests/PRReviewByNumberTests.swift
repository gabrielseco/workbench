import Foundation
import Testing

@testable import WorkbenchCore

/// A `gh` that answers `pr view` with a canned JSON object.
private struct FakeViewGH {
    let runner: GitRunner
    let dir: URL

    /// What `GH_REPO` was when `gh` ran.
    var seenRepo: String { (try? String(contentsOf: dir.appendingPathComponent("repo"), encoding: .utf8)) ?? "" }

    init(in r: ReviewedPR, json: String? = nil, fails: Bool = false, ghRepo: String? = nil) throws {
        dir = r.fx.repo.deletingLastPathComponent().appendingPathComponent("gh-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("gh")
        let answer = json ?? Self.view(branch: "workbench/\(r.id)")
        try """
            #!/bin/sh
            echo "${GH_REPO:-unset}" > "\(dir.path)/repo"
            \(fails ? "echo 'HTTP 404: not found' >&2; exit 1" : "cat <<'EOF'\n\(answer)\nEOF")
            """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        var env = ["PATH": "/usr/bin:/bin"]
        if let ghRepo { env["GH_REPO"] = ghRepo }
        runner = GitRunner(executable: script, environment: env, timeout: 10)
    }

    static func view(
        branch: String, base: String = "main", title: String = "fix: the thing", body: String = "It fixes the thing.",
        state: String = "OPEN", fork: Bool = false
    ) -> String {
        """
        {"headRefName":"\(branch)","baseRefName":"\(base)","title":"\(title)","body":"\(body)","state":"\(state)",\
        "isCrossRepository":\(fork)}
        """
    }
}

@Suite struct PRReviewByNumberTests {
    private func review(
        _ r: ReviewedPR, gh: FakeViewGH, spec: (text: String, path: String)? = nil, again: Bool = false
    ) async throws -> PRReviewResult {
        // A real origin has the base branch; the fixture's only has the shipped one.
        _ = try await r.fx.git.run(["push", "-q", "origin", "main:refs/heads/main"], in: r.fx.repo)
        return try await r.fx.service.reviewPullRequest(
            number: 12, spec: spec, config: r.config, gh: gh.runner, again: again, codexPath: r.codex.path,
            environment: r.codex.environment(), timeout: 30, capacityBackoff: { _ in 0 })
    }

    private func kept(_ r: ReviewedPR) -> URL {
        r.fx.project.workbenchDirectory.appendingPathComponent("reviews/pr-12-\(r.head.prefix(7))")
    }

    @Test func aPullRequestWithNoThreadIsReviewedFromItsOwnTextAndKeptUnderReviews() async throws {
        let r = try await reviewedPR()
        let before = try r.fx.events(r.id).count
        let result = try await review(r, gh: FakeViewGH(in: r))

        #expect(result.verdict == .clean, "\(result.failure ?? "")")
        #expect(result.pr == 12 && result.headSHA == r.head)
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("fix: the thing") && brief.contains("It fixes the thing."), "the PR's own text is the goal")
        #expect(result.findingsPath == ".workbench/reviews/pr-12-\(r.head.prefix(7))/round-1.findings.md")
        #expect(FileManager.default.fileExists(atPath: kept(r).appendingPathComponent("round-1.findings.md").path))
        #expect(FileManager.default.fileExists(atPath: kept(r).appendingPathComponent("round-1.transcript.txt").path))
        #expect(try r.fx.events(r.id).count == before, "no thread, so nothing is written to a log")
        let trees = (try? FileManager.default.contentsOfDirectory(atPath: kept(r).path))?.filter { $0.hasSuffix(".tree") }
        #expect(trees?.isEmpty == true, "the throwaway checkout is gone: \(trees ?? [])")
    }

    @Test func aSpecFileReplacesThePullRequestText() async throws {
        let r = try await reviewedPR()
        let result = try await review(
            r, gh: FakeViewGH(in: r), spec: (text: "THE SPEC: never block the main actor", path: "/tmp/spec.md"))
        #expect(result.verdict == .clean, "\(result.failure ?? "")")
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("THE SPEC: never block the main actor") && !brief.contains("It fixes the thing."))
    }

    @Test func aBranchThatHasNotMovedIsNotReviewedAgainWithoutAgain() async throws {
        let r = try await reviewedPR()
        let gh = try FakeViewGH(in: r)
        _ = try await review(r, gh: gh)
        do {
            _ = try await review(r, gh: gh)
            Issue.record("a second review of the same commit ran")
        } catch let error as PRReviewRefusal {
            #expect(error == .alreadyReviewed(round: 1))
        }
        #expect(r.codex.runs == 1)
        let again = try await review(r, gh: gh, again: true)
        #expect(again.verdict == .clean && r.codex.runs == 2, "--again reviews it once more, with no cap to reach")
    }

    @Test func aFailedReviewIsNoVerdictNeverClean() async throws {
        let r = try await reviewedPR(answer: "looks fine to me\n")
        let result = try await review(r, gh: FakeViewGH(in: r))
        #expect(result.verdict == nil && result.failure != nil, "\(String(describing: result.verdict))")
    }

    @Test(arguments: [
        ("closed", FakeViewGH.view(branch: "workbench/x", state: "CLOSED"), "not open"),
        ("merged", FakeViewGH.view(branch: "workbench/x", state: "MERGED"), "not open"),
        ("fork", FakeViewGH.view(branch: "workbench/x", fork: true), "fork"),
        ("badbranch", FakeViewGH.view(branch: "--upload-pack=x"), "branch name"),
        ("badbase", FakeViewGH.view(branch: "workbench/x", base: "main; rm"), "branch name"),
    ])
    func aPullRequestItCannotReadSafelyIsRefusedBeforeCodexRuns(label: String, json: String, why: String) async throws {
        let r = try await reviewedPR()
        do {
            _ = try await review(r, gh: FakeViewGH(in: r, json: json))
            Issue.record("\(label) was reviewed")
        } catch let error as PRReviewRefusal {
            #expect("\(error)".contains(why), "\(error)")
        }
        #expect(r.codex.runs == 0)
    }

    @Test func ghFailingIsSaidWithItsOwnWordsAndCodexDoesNotRun() async throws {
        let r = try await reviewedPR()
        do {
            _ = try await review(r, gh: FakeViewGH(in: r, fails: true))
            Issue.record("a review ran without the pull request")
        } catch let error as PRReviewRefusal {
            #expect("\(error)".contains("HTTP 404"), "\(error)")
        }
        #expect(r.codex.runs == 0)
    }

    @Test func aLiveReviewOfTheSameCommitIsNotDisturbedAndTheNextOneIsRefusedAsBusy() async throws {
        let r = try await reviewedPR()
        let held = try #require(FolderLock(folder: kept(r)), "the first review takes the lock")
        do {
            _ = try await review(r, gh: FakeViewGH(in: r))
            Issue.record("a second review ran while the first held the commit")
        } catch let error as PRReviewRefusal {
            #expect(error == .busy)
        }
        #expect(r.codex.runs == 0)
        held.release()
        let result = try await review(r, gh: FakeViewGH(in: r))
        #expect(result.verdict == .clean, "the lock is released with the review: \(result.failure ?? "")")
    }

    @Test func whatAKilledReviewLeftBehindIsEndedFirstEvenForAnOlderCommitOrBeforeARefusal() async throws {
        let r = try await reviewedPR()
        let reviews = r.fx.project.workbenchDirectory.appendingPathComponent("reviews")
        func leave(_ folder: String) async throws -> URL {
            let tree = reviews.appendingPathComponent("\(folder)/round-1.tree")
            try FileManager.default.createDirectory(at: tree.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await r.fx.git.run(["worktree", "add", "--detach", tree.path, r.head], in: r.fx.repo)
            return tree
        }
        let older = try await leave("pr-12-aaaaaaa")
        let current = try await leave("pr-12-\(r.head.prefix(7))")
        try "an answer from the killed run\n".write(
            to: kept(r).appendingPathComponent("round-1.findings.md"), atomically: true, encoding: .utf8)

        do {
            _ = try await review(r, gh: FakeViewGH(in: r))
            Issue.record("a commit with an answer was reviewed again")
        } catch let error as PRReviewRefusal {
            #expect(error == .alreadyReviewed(round: 1))
        }
        let list = try await r.fx.git.run(["worktree", "list", "--porcelain"], in: r.fx.repo).stdout
        #expect(!FileManager.default.fileExists(atPath: older.path) && !FileManager.default.fileExists(atPath: current.path))
        #expect(!list.contains("round-1.tree"), "no registered checkout is left: \(list)")
    }

    @Test func aFolderAnotherLiveReviewHoldsIsLeftAlone() async throws {
        let r = try await reviewedPR()
        let reviews = r.fx.project.workbenchDirectory.appendingPathComponent("reviews")
        let tree = reviews.appendingPathComponent("pr-12-bbbbbbb/round-1.tree")
        try FileManager.default.createDirectory(at: tree.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await r.fx.git.run(["worktree", "add", "--detach", tree.path, r.head], in: r.fx.repo)
        let live = try #require(FolderLock(folder: tree.deletingLastPathComponent()))
        _ = try await review(r, gh: FakeViewGH(in: r))
        #expect(FileManager.default.fileExists(atPath: tree.path), "a live review's checkout is not removed")
        live.release()
    }

    @Test func aGHRepoInTheEnvironmentDoesNotPointGhAtAnotherRepository() async throws {
        let r = try await reviewedPR()
        let gh = try FakeViewGH(in: r, ghRepo: "someone/else")
        _ = try await review(r, gh: gh)
        #expect(gh.seenRepo.trimmingCharacters(in: .whitespacesAndNewlines) == "unset", "\(gh.seenRepo)")
    }

    @Test func aBranchNotOnOriginIsRefused() async throws {
        let r = try await reviewedPR()
        do {
            _ = try await review(r, gh: FakeViewGH(in: r, json: FakeViewGH.view(branch: "no/such-branch")))
            Issue.record("a branch that is not on origin was reviewed")
        } catch is PRReviewRefusal {
        }
        #expect(r.codex.runs == 0)
    }
}
