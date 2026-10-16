import Foundation
import Testing

@testable import WorkbenchCore

// MARK: the command

private struct CLIRun {
    var code: Int32?
    var stdout: String
    var stderr: String
}

private func runCLI(_ arguments: [String], _ r: ReviewedPR) async throws -> CLIRun {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: [
            "PATH": "\(r.codex.dir.path):/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
            "CODEX_FAKE_DIR": r.codex.dir.path,
        ],
        workingDirectory: r.fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    let process = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in process.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return CLIRun(code: code, stdout: lines.joined(separator: "\n"), stderr: exit?.stderrTail ?? "")
}

@Suite struct PRReviewCommandTests {
    @Test func cleanExitsZeroAndPrintsTheFindings() async throws {
        let r = try await reviewedPR(answer: "Nothing to fix.\nVERDICT: CLEAN")
        let run = try await runCLI(["pr-review"], r)
        #expect(run.code == 0, "\(run)")
        #expect(run.stdout.contains("Nothing to fix.") && run.stdout.contains("round 1 of 3, pull request #12: clean"))
        #expect(r.codex.runs == 1)
    }

    @Test func findingsExitFifteenAndSayHowManyReviewsAreLeft() async throws {
        let r = try await reviewedPR(answer: "1. Boom.\nVERDICT: FIX")
        let run = try await runCLI(["pr-review", r.id], r)
        #expect(run.code == 15, "\(run)")
        #expect(run.stdout.contains("1. Boom.") && run.stdout.contains("findings to fix (2 reviews left)"))
    }

    @Test func noVerdictExitsOneAndSaysWhy() async throws {
        let r = try await reviewedPR(answer: "I could not decide.")
        let run = try await runCLI(["pr-review"], r)
        #expect(run.code == 1, "\(run)")
        #expect(run.stdout.contains("no verdict for round 1 of 3") && run.stdout.contains("VERDICT"))
    }

    @Test func refusalsExitSixAndNothingRuns() async throws {
        let r = try await reviewedPR()
        #expect(try await runCLI(["pr-review"], r).code == 0)
        let again = try await runCLI(["pr-review"], r)
        #expect(again.code == 6 && again.stderr.contains("refused") && again.stderr.contains("--again"), "\(again)")
        #expect(r.codex.runs == 1)
        let noPR = try await RunnerFixture()
        _ = try await noPR.approvedThread()
        let other = ReviewedPR(fx: noPR, id: "", bare: r.bare, head: "", codex: r.codex, config: r.config)
        let none = try await runCLI(["pr-review"], other)
        #expect(none.code == 6 && none.stderr.contains("workbench ship"), "\(none)")
        #expect(r.codex.runs == 1)
    }

    @Test func usageAndUnknownThread() async throws {
        let r = try await reviewedPR()
        #expect(try await runCLI(["pr-review", "--bogus"], r).code == 2)
        #expect(try await runCLI(["pr-review", "no-such-thread"], r).code == 7)
        #expect(r.codex.runs == 0)
    }

    @Test func reviewJSONCarriesTheRoundAndWhetherItIsStale() async throws {
        let r = try await reviewedPR(answer: "bug\nVERDICT: FIX")
        let before = try await runCLI(["review", "--json"], r)
        #expect(before.stdout.contains("\"pr_review\":null"), "\(before.stdout)")

        _ = try await runCLI(["pr-review"], r)
        let after = try await runCLI(["review", "--json"], r)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(after.stdout.utf8)) as? [String: Any])
        let round = try #require(object["pr_review"] as? [String: Any])
        #expect(round["round"] as? Int == 1 && round["verdict"] as? String == "fix" && round["ok"] as? Bool == true)
        #expect(round["stale"] as? Bool == false && round["head_sha"] as? String == r.head)
        #expect(round["findings_path"] as? String == "pr-review/round-1.findings.md" && round["failure"] is NSNull)
        #expect(round["pr"] as? Int == 12)
        #expect(object["v"] as? Int == 1)

        let text = try await runCLI(["review"], r)
        #expect(text.stdout.contains("PR review  round 1 · findings to fix"), "\(text.stdout)")
    }
}
