import Foundation
import Testing

@testable import WorkbenchCore

/// A `gh` for follow-ups: its pull request list reports the branch's head as the origin has it right now.
private func writeLoopGH(_ r: ReviewedPR) throws -> URL {
    let dir = r.fx.repo.deletingLastPathComponent().appendingPathComponent("loopgh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("gh")
    try """
        #!/bin/sh
        echo "$@" >> "$GH_FAKE_DIR/calls"
        case "$1 $2" in
        "auth status") exit 0 ;;
        "pr list")
          head=""; prev=""
          for a in "$@"; do [ "$prev" = "--head" ] && head="$a"; prev="$a"; done
          sha=$(git --git-dir="$GH_FAKE_ORIGIN" rev-parse "refs/heads/$head")
          url="https://github.com/o/r/pull/12"
          printf '[{"number":12,"url":"%s",' "$url"
          printf '"headRefName":"%s","baseRefName":"main","headRefOid":"%s"}]\n' "$head" "$sha"
          exit 0 ;;
        esac
        exit 2
        """.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    return dir
}

private struct LoopRun {
    var code: Int32?
    var text: String
}

private func runLoop(
    _ arguments: [String], _ r: ReviewedPR, gh: URL, claude: String = "write=a.txt",
    attach: @Sendable (ProcessRun) -> Void = { _ in }
) async throws -> LoopRun {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: [
            "PATH": "\(gh.path):\(r.codex.dir.path):/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
            "GH_FAKE_DIR": gh.path, "GH_FAKE_ORIGIN": r.bare.path, "CODEX_FAKE_DIR": r.codex.dir.path,
            "FAKE_CLAUDE": claude,
        ],
        workingDirectory: r.fx.repo, timeout: 300)
    spawn.snapshotInterval = 3600
    // Ctrl-C is a graceful shutdown (sweep, remove the checkout, record): on a loaded machine it needs more than 5 s.
    spawn.killGrace = 90
    let process = try ProcessRunner.start(spawn)
    attach(process)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in process.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return LoopRun(code: code, text: (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
}

/// A shipped thread whose pull request is on a branch the origin has, ready for `ship --review-loop`. `answers` are what
/// Codex says on its first, second, ... review.
private func loopPR(maxRounds: Int = 3, answers: [String]) async throws -> (r: ReviewedPR, gh: URL) {
    let r = try await reviewedPR(
        extraConfig: "check_command = \"true\"\n[pr_review]\nmax_rounds = \(maxRounds)\n", answer: nil)
    for (index, answer) in answers.enumerated() { try r.codex.put("answer_\(index + 1)", answer) }
    return (r, try writeLoopGH(r))
}

private func originTip(_ r: ReviewedPR) async throws -> String {
    try await shipOut(["rev-parse", "refs/heads/workbench/\(r.id)"], r.bare, r.fx)
}

private let fix1 = "1. A.swift:3 crashes on empty input\nVERDICT: FIX"
private let clean = "Nothing left.\nVERDICT: CLEAN"

@Suite struct ReviewLoopCommandTests {
    @Test func aFixRoundStartsAFollowUpPushesItAndTheNextReviewIsClean() async throws {
        let (r, gh) = try await loopPR(answers: [fix1, clean])
        let before = await (try originTip(r), try String(contentsOf: r.fx.project.goalURL(r.id), encoding: .utf8))

        let run = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        #expect(run.code == 0, "\(run.text)")
        #expect(run.text.contains("round 1 found things to fix: follow-up thread"))
        #expect(run.text.contains("the review is clean after 2 rounds"))
        #expect(r.codex.runs == 2)

        let after = try await originTip(r)
        #expect(after != before.0, "the fix was pushed to the pull request's branch")
        let store = ThreadStore(project: r.fx.project)
        let kids = store.followUps(of: r.id)
        #expect(kids.count == 1 && kids[0].decision == "accepted")
        let child = kids[0].id
        #expect(kids[0].lineage == ThreadLineage(parent: r.id, root: r.id, round: 1))
        #expect(try r.fx.kinds(child).contains("pr.opened"), "the follow-up's push was recorded against the same pull request")

        // The finished thread is not reopened: its goal and decision are as they were, and it only gained a review.
        #expect(try String(contentsOf: r.fx.project.goalURL(r.id), encoding: .utf8) == before.1)
        #expect(store.state(of: r.id).decision == "accepted")
        let rootKinds = try r.fx.kinds(r.id)
        #expect(rootKinds.filter { $0 == "turn.started" }.count == 1, "no turn was added to the shipped thread")
        #expect(rootKinds.suffix(2) == ["pr_review.started", "pr_review.finished"])
        // Round 2 was the follow-up's own, counted with round 1.
        let childStarted = try r.fx.events(child).first { $0.kind == .prReviewStarted }
        #expect(childStarted?.data["round"]?.intValue == 2 && childStarted?.data["head_sha"]?.stringValue == after)
        let goal = try String(contentsOf: r.fx.project.goalURL(child), encoding: .utf8)
        #expect(goal.contains("> 1. A.swift:3 crashes on empty input"))
    }

    @Test func twoRoundsOfFindingsMakeAChainOfFollowUpsAndStayUnderTheSameRoot() async throws {
        let (r, gh) = try await loopPR(answers: [fix1, fix1, clean])
        let run = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        #expect(run.code == 0 && run.text.contains("the review is clean after 3 rounds"), "\(run.text)")
        let kids = ThreadStore(project: r.fx.project).followUps(of: r.id)
        #expect(kids.count == 2 && kids.allSatisfy { $0.decision == "accepted" })
        #expect(kids[0].lineage == ThreadLineage(parent: r.id, root: r.id, round: 1))
        #expect(kids[1].lineage == ThreadLineage(parent: kids[0].id, root: r.id, round: 2), "the second follows the first")
        #expect(r.codex.runs == 3)
        let rounds = try r.fx.events(kids[1].id).filter { $0.kind == .prReviewStarted }.compactMap { $0.data["round"]?.intValue }
        #expect(rounds == [3], "numbering continues across the tree")
        let tree = try await runLoop(["status", kids[0].id], r, gh: gh)
        #expect(tree.text.contains("follows:   \(r.id)"), "\(tree.text)")
        #expect(tree.text.contains("round 2  \(kids[1].id)  accepted"), "\(tree.text)")
    }

    @Test func aThreadThatWasNotShippedYetIsShippedAndThenReviewed() async throws {
        let fx = try await RunnerFixture(extraConfig: "check_command = \"true\"\n[pr_review]\nmax_rounds = 3\n")
        let (id, _) = try await acceptedThread(fx)
        let bare = try await addOrigin(fx)
        let codex = try FakeCodex(in: fx)
        try codex.put("answer", clean)
        let config = try Config.load(from: fx.project.configURL)
        let r = ReviewedPR(fx: fx, id: id, bare: bare, head: "", codex: codex, config: config)
        let gh = try writeLoopGH(r)

        let run = try await runLoop(["ship", id, "--review-loop", "--yes", "--no-describe"], r, gh: gh)
        #expect(run.code == 0, "\(run.text)")
        #expect(run.text.contains("pushed workbench/\(id)") && run.text.contains("the review is clean after 1 round"))
        let kinds = try fx.kinds(id)
        let opened = try #require(kinds.firstIndex(of: "pr.opened"))
        let review = try #require(kinds.firstIndex(of: "pr_review.started"))
        #expect(review > opened, "the review came after the pull request was recorded")
    }

    @Test func aBranchThatMovedAfterTheLastAllowedReviewIsNotReportedClean() async throws {
        let (r, gh) = try await loopPR(maxRounds: 1, answers: [clean])
        #expect(try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh).code == 0)

        // Someone pushes more commits; the only allowed review looked at the commit before.
        let worktree = r.fx.project.worktreesDirectory.appendingPathComponent(r.id)
        _ = try await r.fx.git.run(["worktree", "add", "-q", worktree.path, "workbench/\(r.id)"], in: r.fx.repo)
        try "later\n".write(to: worktree.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        _ = try await r.fx.git.run(["add", "-A"], in: worktree)
        _ = try await r.fx.git.run(["commit", "-q", "-m", "more"], in: worktree)
        _ = try await r.fx.git.run(["push", "-q", "origin", "HEAD:refs/heads/workbench/\(r.id)"], in: worktree)

        let again = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        #expect(again.code == 6, "\(again.text)")
        #expect(again.text.contains("the branch has moved since round 1") && !again.text.contains("review is clean"))
        #expect(r.codex.runs == 1)
    }

    @Test func aFailedLastReviewIsStillAFailureWhenTheLoopIsStartedAgain() async throws {
        let (r, gh) = try await loopPR(maxRounds: 1, answers: ["no verdict at all"])
        let first = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        let second = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        #expect(first.code == 1 && second.code == 1, "\(first.code ?? -1) then \(second.code ?? -1): \(second.text)")
        #expect(second.text.contains("has no verdict"))
        #expect(r.codex.runs == 1)
    }

    @Test func findingsLeftAtTheCapExitFifteenWithoutAnotherFollowUp() async throws {
        let (r, gh) = try await loopPR(maxRounds: 2, answers: [fix1, fix1])
        let run = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        #expect(run.code == 15, "\(run.text)")
        #expect(run.text.contains("max_rounds (2) is reached"))
        #expect(ThreadStore(project: r.fx.project).followUps(of: r.id).count == 1, "max_rounds - 1 follow-ups, no more")
        #expect(r.codex.runs == 2)
    }

    @Test func aCleanFirstReviewStartsNothing() async throws {
        let (r, gh) = try await loopPR(answers: [clean])
        let run = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        #expect(run.code == 0 && run.text.contains("the review is clean after 1 round"), "\(run.text)")
        #expect(ThreadStore(project: r.fx.project).followUps(of: r.id).isEmpty)
    }

    @Test func aReviewerWithoutAVerdictStopsTheLoop() async throws {
        let (r, gh) = try await loopPR(answers: ["I am not sure."])
        let run = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        #expect(run.code == 1 && run.text.contains("no verdict for round 1"), "\(run.text)")
        #expect(ThreadStore(project: r.fx.project).followUps(of: r.id).isEmpty)
    }

    @Test func aFailingCheckStopsTheLoopAndPushesNothing() async throws {
        let (r, gh) = try await loopPR(answers: [fix1, clean])
        let config = try String(contentsOf: r.fx.project.configURL, encoding: .utf8)
        try config.replacingOccurrences(of: "check_command = \"true\"", with: "check_command = \"false\"")
            .write(to: r.fx.project.configURL, atomically: true, encoding: .utf8)
        let tip = try await originTip(r)

        let run = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        #expect(run.code == 13, "\(run.text)")
        #expect(run.text.contains("check-failed") && run.text.contains("Nothing was pushed"))
        #expect(try await originTip(r) == tip)
        let kid = try #require(ThreadStore(project: r.fx.project).followUps(of: r.id).first)
        #expect(kid.decision == nil, "the follow-up is left awaiting review for the person")
        #expect(r.codex.runs == 1)
    }

    @Test func aFollowUpThatChangesNothingIsNotPushedAndIsSaid() async throws {
        let (r, gh) = try await loopPR(answers: [fix1, clean])
        let tip = try await originTip(r)
        let run = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh, claude: "stream-events=0")
        #expect(run.code == 15, "\(run.text)")
        #expect(run.text.contains("the follow-up changed nothing, so the findings were not acted on"))
        #expect(try await originTip(r) == tip && r.codex.runs == 1)
    }

    @Test func aFailedTurnStopsTheLoop() async throws {
        let (r, gh) = try await loopPR(answers: [fix1, clean])
        let tip = try await originTip(r)
        let run = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh, claude: "no-result")
        #expect(run.code == 1, "\(run.text)")
        #expect(try await originTip(r) == tip && r.codex.runs == 1)
    }

    @Test func withoutYesAndWithoutATerminalNothingIsSpent() async throws {
        let (r, gh) = try await loopPR(answers: [fix1])
        let run = try await runLoop(["ship", r.id, "--review-loop"], r, gh: gh)
        #expect(run.code == 6 && run.text.contains("no terminal to ask on"), "\(run.text)")
        #expect(r.codex.runs == 0)
        let both = try await runLoop(["ship", r.id, "--review-loop", "--watch", "--yes"], r, gh: gh)
        #expect(both.code == 2, "\(both.text)")
    }

    @Test func stoppingTheLoopDuringTheReviewEndsItAndLeavesNothingRunning() async throws {
        let (r, gh) = try await loopPR(answers: [fix1])
        try r.codex.put("hang", "")
        let dir = r.codex.dir
        let run = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh) { process in
            Task {
                _ = await pollUntil { FileManager.default.fileExists(atPath: dir.appendingPathComponent("calls").path) }
                try await Task.sleep(nanoseconds: 300_000_000)
                process.stop()
            }
        }
        #expect(run.code == 3, "\(run.text)")
        let pid = try #require(Int32(r.codex.read("pid")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        #expect(await pollUntil { kill(pid, 0) != 0 }, "codex is gone")
        #expect(try r.fx.events(r.id).filter { $0.kind == .prReviewFinished }.count == 1)
    }

    @Test func statusAndReviewShowTheTreeOfFollowUps() async throws {
        let (r, gh) = try await loopPR(answers: [fix1, clean])
        _ = try await runLoop(["ship", r.id, "--review-loop", "--yes"], r, gh: gh)
        let kid = try #require(ThreadStore(project: r.fx.project).followUps(of: r.id).first).id

        let rootStatus = try await runLoop(["status", r.id], r, gh: gh)
        #expect(rootStatus.text.contains("follow-ups: 1"), "\(rootStatus.text)")
        #expect(rootStatus.text.contains("round 1  \(kid)  accepted"), "\(rootStatus.text)")
        let kidStatus = try await runLoop(["status", kid], r, gh: gh)
        #expect(kidStatus.text.contains("follows:   \(r.id)  (review follow-up 1 of \(r.id))"), "\(kidStatus.text)")
        let review = try await runLoop(["review", r.id], r, gh: gh)
        #expect(review.text.contains("follow-ups: 1"))

        let json = try await runLoop(["status", r.id, "--json"], r, gh: gh)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.text.utf8)) as? [String: Any])
        let kids = try #require(root["follow_ups"] as? [[String: Any]])
        #expect(root["lineage"] is NSNull && kids.count == 1 && kids[0]["thread"] as? String == kid)
        #expect(kids[0]["round"] as? Int == 1 && kids[0]["ended"] as? String == "accepted")
        let kidJSON = try await runLoop(["review", kid, "--json"], r, gh: gh)
        let child = try #require(try JSONSerialization.jsonObject(with: Data(kidJSON.text.utf8)) as? [String: Any])
        let lineage = try #require(child["lineage"] as? [String: Any])
        #expect(lineage["parent"] as? String == r.id && lineage["root"] as? String == r.id && lineage["round"] as? Int == 1)
        let all = try await runLoop(["status", "--all", "--json"], r, gh: gh)
        let list = try #require(try JSONSerialization.jsonObject(with: Data(all.text.utf8)) as? [String: Any])
        let threads = try #require(list["threads"] as? [[String: Any]])
        let entry = try #require(threads.first { $0["thread"] as? String == kid })
        #expect(entry["parent"] as? String == r.id && entry["root"] as? String == r.id && entry["round"] as? Int == 1)
    }
}
