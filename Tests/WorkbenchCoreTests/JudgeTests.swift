import Foundation
import Testing

@testable import WorkbenchCore

private func criteria(_ ids: String...) -> [Criterion] {
    ids.map { Criterion(id: $0, text: "text of \($0)", proof: "proof of \($0)") }
}

private func output(_ verdict: String, error: Bool = false) -> String {
    let result = verdict.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return #"{"type":"result","is_error":\#(error),"result":"\#(result)","total_cost_usd":0.0123}"#
}

private let good = """
    {"criteria": [{"id": "c1", "met": true, "evidence": ["The card reads Received this month."]},
                  {"id": "c2", "met": false, "evidence": ["The test log shows 2 failures."]}],
     "concerns": ["The filtered label was left alone."]}
    """

@Suite struct JudgeParseTests {
    @Test func aGoodVerdictIsReadInTheGoalsOrderWithItsCost() throws {
        let parsed = try Judge.parse(output: output(good), criteria: criteria("c1", "c2"))
        #expect(parsed.verdict.criteria.map(\.id) == ["c1", "c2"])
        #expect(parsed.verdict.criteria.map(\.met) == [true, false])
        #expect(parsed.verdict.criteria[0].evidence == ["The card reads Received this month."])
        #expect(parsed.verdict.concerns == ["The filtered label was left alone."])
        #expect(parsed.costUSD == 0.0123)
        let swapped = #"{"criteria":[{"id":"c2","met":true,"evidence":[]},{"id":"c1","met":true,"evidence":[]}],"concerns":[]}"#
        let reordered = try Judge.parse(output: output(swapped), criteria: criteria("c1", "c2"))
        #expect(reordered.verdict.criteria.map(\.id) == ["c1", "c2"])
    }

    @Test func aVerdictInAFenceOrWithAnIntroIsStillRead() throws {
        let wrapped = "Here is my verdict:\n```json\n" + good + "\n```"
        #expect(try Judge.parse(output: output(wrapped), criteria: criteria("c1", "c2")).verdict.criteria.count == 2)
    }

    private static func answer(_ entries: String..., tail: String = ", \"concerns\": []") -> String {
        "{\"criteria\": [" + entries.joined(separator: ", ") + "]" + tail + "}"
    }

    private static func entry(_ id: String, met: String = "true", evidence: String = ", \"evidence\": []") -> String {
        "{\"id\": \"\(id)\", \"met\": \(met)\(evidence)}"
    }

    @Test(arguments: [
        ("not json at all", "not a JSON object"),
        (answer(entry("c1")), "no verdict for [c2]"),
        (answer(entry("c9"), entry("c1"), entry("c2")), "does not have"),
        (answer(entry("c1"), entry("c1"), entry("c2")), "twice"),
        (answer(entry("c1", met: "\"yes\""), entry("c2")), "true or false"),
        (answer(entry("c1", met: "1"), entry("c2", met: "0")), "true or false"),
        (answer(entry("c1", evidence: ""), entry("c2")), "'evidence'"),
        (answer(entry("c1", evidence: ", \"evidence\": \"a\""), entry("c2")), "'evidence'"),
        ("{\"criteria\": \"all\"}", "no list of criteria"),
        (answer(entry("c1"), entry("c2"), tail: ", \"concerns\": \"x\""), "'concerns'"),
        (answer(entry("c1"), entry("c2"), tail: ""), "'concerns'"),
    ])
    func anUnusableAnswerIsRefusedWithAReason(answer: String, why: String) {
        do {
            _ = try Judge.parse(output: output(answer), criteria: criteria("c1", "c2"))
            Issue.record("expected a refusal for \(answer)")
        } catch { #expect("\(error)".contains(why), "\(error)") }
    }

    @Test func anErrorFromClaudeAndAMissingResultAreRefused() {
        #expect(throws: JudgeError.self) { try Judge.parse(output: output(good, error: true), criteria: criteria("c1", "c2")) }
        #expect(throws: JudgeError.self) { try Judge.parse(output: #"{"type":"result"}"#, criteria: criteria("c1")) }
    }

    @Test func evidenceAndConcernsAreBounded() throws {
        let long = String(repeating: "x", count: 1000)
        let many = (0..<20).map { "\"concern \($0)\"" }.joined(separator: ",")
        let answer = """
            {"criteria": [{"id": "c1", "met": true, "evidence": ["\(long)", "b", "c", "d", "e"]}], "concerns": [\(many)]}
            """
        let verdict = try Judge.parse(output: output(answer), criteria: criteria("c1")).verdict
        #expect(verdict.criteria[0].evidence.count == 3)
        #expect(verdict.criteria[0].evidence[0].count == 300)
        #expect(verdict.concerns.count == 8)
    }
}

@Suite struct JudgeRequestTests {
    private func input(
        screenshots: [String] = [], check: Review.Check? = nil, verify: Review.Verify? = nil, lastTurn: Int = 1
    ) throws -> JudgeInput {
        let text = """
            ---
            id: g-1
            title: T
            base: main
            budget_usd: 1
            turn_timeout_min: 5
            ---

            ## Request

            Change the label.

            ## Criteria

            - [c1] It reads new.
              - proof: screenshot: income

            ## Out of scope

            - Other labels.
            """
        let goal = try GoalFile.parse(text).goal
        return JudgeInput(
            goal: goal, diff: "+new", diffTruncated: false, check: check, checkOutput: nil, verify: verify,
            screenshots: screenshots, lastTurn: lastTurn)
    }

    @Test func thePromptCarriesTheGoalTheEvidenceAndTheRules() throws {
        let verify = Review.Verify(
            turn: 1, result: "passed", exitCode: 0, durationMs: 1, outputRef: nil, command: nil,
            proof: [ProofFile(name: "income.png", path: "proof/turn-1/income.png", sha256: "a", bytes: 1)])
        let prompt = Judge.prompt(for: try input(screenshots: ["income.png"], verify: verify))
        #expect(prompt.contains("[c1] It reads new."))
        #expect(prompt.contains("proof: screenshot: income"))
        #expect(prompt.contains("Open these with Read"))
        #expect(prompt.contains("- income.png"))
        #expect(prompt.contains("It left: income.png."))
        #expect(prompt.contains("```diff\n+new\n```"))
        #expect(prompt.contains("Other labels."))
        #expect(prompt.contains("evidenced violation"), "the rule that keeps it from failing on a hunch")
        #expect(prompt.contains("The project's check did not run."))
    }

    @Test func anOlderCheckOrVerifyIsCalledStale() throws {
        let check = Review.Check(turn: 1, result: "passed", exitCode: 0, durationMs: 1, outputRef: nil, command: "x")
        let prompt = Judge.prompt(for: try input(check: check, lastTurn: 2))
        #expect(prompt.contains("not the latest turn 2"))
        #expect(prompt.contains("The command was `x`."))
    }

    @Test func thePromptHidesMachinePaths() throws {
        var request = try input()
        request.diff = "+path /Users/gabriel/secret/file"
        #expect(!Judge.prompt(for: request).contains("/Users/gabriel"))
    }

    @Test func screenshotsGetReadAndTheirFolderOtherwiseNoTools() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\"]\n")
        let with = Judge.arguments(config: config, prompt: "p", withScreenshots: true)
        #expect(with.contains("Read") && with.contains("--allowedTools") && with.contains("--restricted"))
        #expect(!with.contains("Bash") && !with.contains("--resume"))
        let without = Judge.arguments(config: config, prompt: "p", withScreenshots: false)
        #expect(without.contains("--tools") && !without.contains("--allowedTools"))
        #expect(without.suffix(2) == ["--", "p"])
        let tuned = Judge.arguments(config: config, prompt: "p", withScreenshots: false, budget: 2, model: "haiku")
        #expect(tuned.contains("haiku") && tuned.contains("2"))
    }
}

private struct Judged {
    var fx: RunnerFixture
    var id: String
    var config: Config
    var dir: URL

    func file(_ name: String, _ text: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func environment(_ directives: String...) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE": directives.joined(separator: ",")]
    }
}

private func judged(verify: Bool = false) async throws -> Judged {
    var extra = ""
    if verify {
        let script = try CheckScript()
        let path = try script.write("printf pixels > \"$WORKBENCH_PROOF_DIR/home.png\"", name: "verify.sh")
        extra = "verify_command = \"\(path)\""
    }
    let fx = try await RunnerFixture(extraConfig: extra)
    let (id, _) = try await acceptedThread(fx)
    let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("judge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Judged(fx: fx, id: id, config: try Config.load(from: fx.project.configURL), dir: dir)
}

private let oneCriterion = #"{"criteria": [{"id": "c1", "met": true, "evidence": ["a.txt now says hello."]}], "concerns": []}"#

@Suite struct JudgeServiceTests {
    @Test func aVerdictIsRecordedAsItsOwnEventAndShownByReview() async throws {
        let j = try await judged()
        let answer = try j.file("answer.json", oneCriterion)
        let dump = j.dir.appendingPathComponent("dump.json").path
        let turns = try j.fx.events(j.id).filter { $0.kind == .turnStarted }.count

        let result = try await j.fx.service.judge(
            id: j.id, config: j.config, environment: j.environment("answer=\(answer)", "dump=\(dump)"))
        #expect(result.failure == nil)
        #expect(result.verdict?.criteria.map(\.met) == [true])
        #expect(result.costUSD == 0.001)

        let events = try j.fx.events(j.id)
        let event = try #require(events.last)
        #expect(event.kind == .judgeRan && event.data["ok"] == true && event.turn == 1)
        #expect(events.filter { $0.kind == .turnStarted }.count == turns, "not a numbered turn")
        #expect(try j.fx.contents(j.id).isHealthy)

        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("\"--tools\"") && !argv.contains("--allowedTools") && !argv.contains("--resume"))

        let state = ThreadState.derive(from: events, id: j.id)
        #expect(state.review.judge?.verdict?.criteria.first?.evidence == ["a.txt now says hello."])
        let report = ReviewReport(
            state: state, title: "T", criteria: [Criterion(id: "c1", text: "t", proof: "cat a.txt")],
            approval: "approved", goalProblem: nil, diff: .unavailable(reason: "x"))
        let text = report.render().joined(separator: "\n")
        #expect(text.contains("Judge      advisory · turn 1"))
        #expect(text.contains("[c1] met"))
    }

    @Test func itRunsOncePerTurnUnlessAskedAgain() async throws {
        let j = try await judged()
        let env = j.environment("answer=\(try j.file("a.json", oneCriterion))")
        _ = try await j.fx.service.judge(id: j.id, config: j.config, environment: env)
        do {
            _ = try await j.fx.service.judge(id: j.id, config: j.config, environment: env)
            Issue.record("expected a refusal")
        } catch let error as JudgeRefusal { #expect(error == .alreadyJudged(turn: 1)) }
        _ = try await j.fx.service.judge(id: j.id, config: j.config, again: true, environment: env)
        #expect(try j.fx.events(j.id).filter { $0.kind == .judgeRan }.count == 2)
    }

    @Test(arguments: [
        ("not json", "", "not a JSON object"),
        (#"{"criteria": [], "concerns": []}"#, "", "no verdict for [c1]"),
        (oneCriterion, "exit=1", "status 1"),
    ])
    func aFailedJudgeIsRecordedWithItsReasonAndLeavesTheThreadAlone(answer: String, exit: String, why: String) async throws {
        let j = try await judged()
        let file = try j.file("a.json", answer)
        let result = try await j.fx.service.judge(
            id: j.id, config: j.config, environment: j.environment("answer=\(file)", exit))
        #expect(result.verdict == nil)
        #expect(result.failure?.contains(why) == true, "\(result.failure ?? "")")
        let event = try #require(try j.fx.events(j.id).last)
        #expect(event.kind == .judgeRan && event.data["ok"] == false)
        let state = ThreadState.derive(from: try j.fx.events(j.id), id: j.id)
        #expect(state.review.judge?.verdict == nil && state.review.judge?.failure?.contains(why) == true)
        #expect(state.review.status == .decided("accepted"), "advisory: the thread's state is untouched")
        // A failure does not count as having judged the turn.
        let retry = j.environment("answer=\(try j.file("b.json", oneCriterion))")
        _ = try await j.fx.service.judge(id: j.id, config: j.config, environment: retry)
    }

    @Test func withScreenshotsItGetsReadAndRunsInTheirFolder() async throws {
        let j = try await judged(verify: true)
        let dump = j.dir.appendingPathComponent("dump.json").path
        let env = j.environment("answer=\(try j.file("a.json", oneCriterion))", "dump=\(dump)")
        _ = try await j.fx.service.judge(id: j.id, config: j.config, environment: env)
        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("--allowedTools") && argv.contains("\"Read\""))
        #expect(argv.contains("home.png"), "the prompt lists the screenshot")
        let folder = OrphanSweeper.realPath(j.fx.project.proofDirectory(j.id, turn: 1))
        #expect(argv.contains(folder), "it runs where the screenshots are")
    }

    @Test func itSeesUncommittedWorkAndNamesUntrackedFiles() async throws {
        let j = try await judged()
        let worktree = j.fx.project.worktreesDirectory.appendingPathComponent(j.id)
        try "one\nhello\nUNCOMMITTED-LINE\n".write(
            to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: worktree.appendingPathComponent("loose-notes.txt"), atomically: true, encoding: .utf8)
        let dump = j.dir.appendingPathComponent("dump.json").path
        let env = j.environment("answer=\(try j.file("a.json", oneCriterion))", "dump=\(dump)")
        _ = try await j.fx.service.judge(id: j.id, config: j.config, environment: env)
        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("UNCOMMITTED-LINE"), "the judge sees what review shows, not only the commits")
        #expect(argv.contains("loose-notes.txt"), "untracked files are named")
    }

    @Test func itSeesTheSameWorkReviewDoesWhenTheThreadMergedANewerBase() async throws {
        let j = try await judged()
        let fx = j.fx
        try "main change\n".write(to: fx.repo.appendingPathComponent("main-only.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "newer main"], in: fx.repo)
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(j.id)
        let merged = try await fx.git.run(["merge", "-q", "--no-edit", "main"], in: worktree)
        #expect(merged.succeeded, "\(merged.stderr)")

        let dump = j.dir.appendingPathComponent("dump.json").path
        let env = j.environment("answer=\(try j.file("a.json", oneCriterion))", "dump=\(dump)")
        _ = try await fx.service.judge(id: j.id, config: j.config, environment: env)
        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("main-only.txt"), "the diff runs from the commit the worktree was cut from, as review's does")
        #expect(argv.contains("hello"))
    }

    @Test func aJudgeThatStartedAndLeftNoResultShowsAsInterruptedAndDoesNotCountAsJudged() async throws {
        let j = try await judged()
        do {
            let log = try EventLogWriter.open(at: j.fx.project.eventsURL(j.id))
            try await log.append(.judgeStarted, turn: 1, data: ["argv": []])
            await log.close()  // killed here
        }
        let state = ThreadState.derive(from: try j.fx.events(j.id), id: j.id)
        #expect(state.review.judge?.verdict == nil)
        #expect(state.review.judge?.failure?.contains("never recorded a result") == true)
        let env = j.environment("answer=\(try j.file("a.json", oneCriterion))")
        let result = try await j.fx.service.judge(id: j.id, config: j.config, environment: env)
        #expect(result.verdict != nil, "an attempt without a result does not use up the turn")
        let after = ThreadState.derive(from: try j.fx.events(j.id), id: j.id)
        #expect(after.review.judge?.verdict != nil)
    }

    @Test func whileJudgingThisProcessHoldsTheThreadAndLetsGoAfterwards() async throws {
        let j = try await judged()
        let service = j.fx.service
        let id = j.id
        let seen = LockedBox<Int32?>(nil)
        _ = try await service.judge(
            id: id, config: j.config, environment: j.environment("answer=\(try j.file("a.json", oneCriterion))"),
            attach: { _ in seen.set(service.runnerPID(id: id)) })
        #expect(seen.get() == getpid(), "`stop` and a second command can see who holds the thread")
        #expect(service.runnerPID(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: j.fx.project.runnerURL(id).path))
    }

    @Test func twoJudgesCannotSpendOnTheSameTurnAtOnce() async throws {
        let j = try await judged()
        let held = try EventLogWriter.open(at: j.fx.project.eventsURL(j.id))
        do {
            _ = try await j.fx.service.judge(
                id: j.id, config: j.config, environment: j.environment("answer=\(try j.file("a.json", oneCriterion))"))
            Issue.record("expected the thread to be busy")
        } catch let error as JudgeRefusal { #expect(error == .busy) }
        await held.close()
    }

    @Test func stoppingEndsTheJudgeAndRecordsWhy() async throws {
        let j = try await judged()
        let result = try await j.fx.service.judge(
            id: j.id, config: j.config, environment: j.environment("hang-after=1"),
            attach: { run in
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    run.stop()
                }
            })
        #expect(result.verdict == nil)
        #expect(result.failure?.contains("stopped") == true, "\(result.failure ?? "")")
        let event = try #require(try j.fx.events(j.id).last)
        #expect(event.kind == .judgeRan && event.data["ok"] == false)
        #expect(try j.fx.contents(j.id).isHealthy)
    }

    @Test func itRefusesWithoutATurnWhileARunIsLiveAndWithABadModel() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let config = try Config.load(from: fx.project.configURL)
        do {
            _ = try await fx.service.judge(id: id, config: config)
            Issue.record("expected a refusal")
        } catch let error as JudgeRefusal { #expect(error == .noTurn) }

        let j = try await judged()
        do {
            _ = try await j.fx.service.judge(id: j.id, config: j.config, model: "--bad model")
            Issue.record("expected a refusal")
        } catch let error as JudgeRefusal { #expect(error == .invalidModel("--bad model")) }

        let me = getpid()
        let started = try #require(ProcessTree.member(for: me))
        let info: [String: Any] = ["pid": me, "started_seconds": started.startSeconds, "started_micros": started.startMicros]
        try JSONSerialization.data(withJSONObject: info).write(to: j.fx.project.runnerURL(j.id))
        do {
            _ = try await j.fx.service.judge(id: j.id, config: j.config)
            Issue.record("expected a refusal")
        } catch let error as ThreadServiceError { #expect(error == .running(pid: me)) }
    }

    @Test func whereTheJudgeDisagreesWithTheCheckReviewSaysSo() throws {
        func event(_ seq: Int, _ kind: EventKind, _ data: JSONValue, turn: Int = 1) -> Event {
            Event(seq: seq, ts: "t", turn: turn, kind: kind, data: data)
        }
        let events = [
            event(1, .turnStarted, ["session_id": "s"]),
            event(2, .turnEnded, ["result": "succeeded"]),
            event(3, .checkStarted, ["command": "npm test"]),
            event(4, .checkRan, ["result": "passed", "exit_code": 0, "command": "npm test"]),
            event(
                5, .judgeRan,
                [
                    "ok": true,
                    "criteria": [["id": "c1", "met": false, "evidence": ["tests are red"]]],
                    "concerns": ["one thing"],
                ]),
        ]
        let state = ThreadState.derive(from: events, id: "t")
        let report = ReviewReport(
            state: state, title: "T", criteria: [Criterion(id: "c1", text: "t", proof: "`npm test` exits 0")],
            approval: "approved", goalProblem: nil, diff: .unavailable(reason: "x"))
        let lines = report.judgeLines()
        #expect(lines.contains { $0.contains("[c1] not met") })
        #expect(lines.contains { $0.contains("differs: [c1] the check passed, the judge says not met") })
        #expect(lines.contains { $0.contains("concern: one thing") })
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.withLock { value = new } }
    func get() -> T { lock.withLock { value } }
}
