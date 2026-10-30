import Foundation
import Testing

@testable import WorkbenchCore

private let autoVerdict = #"{"criteria": [{"id": "c1", "met": true, "evidence": ["a.txt now says hello."]}], "concerns": []}"#

@Suite(.processGate) struct AutoAdviceTests {
    @Test func theJudgeRunsOnceForTheTurnWhenTheConfigAsksForIt() async throws {
        let j = try await judged(extraConfig: "[review]\nauto = [\"judge\"]\n")
        let env = j.environment("answer=\(try j.file("a.json", autoVerdict))")
        let first = await j.fx.service.runAutoAdvice(id: j.id, config: j.config, environment: env)
        #expect(first == [AutoAdviceResult(name: "judge", outcome: .ran(summary: "1 of 1 criteria met"))])
        #expect(try j.fx.events(j.id).filter { $0.kind == .judgeRan }.count == 1)
        let again = await j.fx.service.runAutoAdvice(id: j.id, config: j.config, environment: env)
        guard case .skipped = again.first?.outcome else {
            Issue.record("expected skipped, got \(again)")
            return
        }
        #expect(try j.fx.events(j.id).filter { $0.kind == .judgeRan }.count == 1, "not run twice for one turn")
    }

    @Test func aJudgeTheGoalSkipsIsNotRunAndNotSpentOn() async throws {
        let j = try await judged(extraConfig: "[review]\nauto = [\"judge\"]\n")
        // The thread is accepted, so the service would refuse; the file is what the advice reads.
        let url = j.fx.project.goalURL(j.id)
        let skipped = try GoalEditor.apply(.setSkip(["judge"]), to: GoalFile.parse(String(contentsOf: url, encoding: .utf8)))
        try skipped.text.write(to: url, atomically: true, encoding: .utf8)
        let env = j.environment("answer=\(try j.file("a.json", autoVerdict))")
        let results = await j.fx.service.runAutoAdvice(id: j.id, config: j.config, environment: env)
        #expect(results == [AutoAdviceResult(name: "judge", outcome: .skipped("the goal skips it"))])
        #expect(try j.fx.events(j.id).allSatisfy { $0.kind != .judgeStarted && $0.kind != .judgeRan })
    }

    @Test func nothingRunsWhenAutoIsEmpty() async throws {
        let j = try await judged()
        let results = await j.fx.service.runAutoAdvice(id: j.id, config: j.config, environment: j.environment())
        #expect(results.isEmpty)
        #expect(try j.fx.events(j.id).allSatisfy { $0.kind != .judgeStarted && $0.kind != .judgeRan })
    }

    @Test func aJudgeWithNoAnswerIsALineNotAFailureOfTheThread() async throws {
        let j = try await judged(extraConfig: "[review]\nauto = [\"judge\"]\n")
        let env = j.environment("answer=\(try j.file("bad.json", "not json"))")
        let results = await j.fx.service.runAutoAdvice(id: j.id, config: j.config, environment: env)
        guard case .failed = results.first?.outcome else {
            Issue.record("expected failed, got \(results)")
            return
        }
        #expect(try j.fx.contents(j.id).isHealthy)
        #expect(ThreadService.describe(results).first?.hasPrefix("auto judge: no answer") == true)
    }

    @Test func aStopAskedBeforeAStepStartsMeansNoStepStarts() async throws {
        let j = try await judged(extraConfig: "[review]\nauto = [\"judge\"]\n")
        let stop = AdviceStop()
        stop.stop()
        let results = await j.fx.service.runAutoAdvice(id: j.id, config: j.config, environment: j.environment(), stop: stop)
        #expect(results == [AutoAdviceResult(name: "judge", outcome: .skipped("stopped"))])
        #expect(try j.fx.events(j.id).allSatisfy { $0.kind != .judgeStarted && $0.kind != .judgeRan })
    }

    @Test func anAutomaticStageUsesTheConfiguredCodexExecutableNotACodexOnPath() async throws {
        let config = """
            [providers.codex]
            executable = "/nonexistent/configured-codex"
            [review]
            stages = ["pr-review", "design"]
            auto = ["design"]
            [review.stage.design]
            skill = "d.md"
            """
        let j = try await judged(extraConfig: config)
        // The stage reads its rubric from the branch it reviews, so the thread's branch gets the file first.
        let worktree = j.fx.project.worktreesDirectory.appendingPathComponent(j.id)
        try "- flag anything unreadable\n".write(to: worktree.appendingPathComponent("d.md"), atomically: true, encoding: .utf8)
        _ = try await j.fx.git.run(["add", "d.md"], in: worktree)
        _ = try await j.fx.git.run(["commit", "-q", "-m", "rubric"], in: worktree)
        let results = await j.fx.service.runAutoAdvice(id: j.id, config: j.config, environment: j.environment())
        guard case .failed(let why)? = results.first?.outcome else {
            Issue.record("expected a failure, got \(results)")
            return
        }
        // Messages scrub absolute paths to <path>: the configured executable was looked for; a bare `codex` would be named.
        let aboutConfigured = why.contains("`<path>` was not found") && !why.contains("`codex`")
        #expect(aboutConfigured, "the refusal is about the configured executable: \(why)")
    }

    @Test func anAutomaticStageWaitsWhileTheTurnsWorkIsUncommitted() async throws {
        let stage = "[review]\nstages = [\"pr-review\", \"design\"]\nauto = [\"design\"]\n"
            + "[review.stage.design]\nskill = \"d.md\"\n"
        let fx = try await RunnerFixture(extraConfig: stage)
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "work\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let config = try Config.load(from: fx.project.configURL)
        let results = await fx.service.runAutoAdvice(id: id, config: config, environment: ["PATH": "/usr/bin:/bin"])
        guard case .skipped(let why)? = results.first?.outcome else {
            Issue.record("expected skipped, got \(results)")
            return
        }
        #expect(why.contains("uncommitted") && why.contains("workbench review-stage design \(id)"), "\(why)")
        #expect(try fx.events(id).allSatisfy { $0.kind != .reviewStageStarted }, "no round was started or counted")
    }
}
