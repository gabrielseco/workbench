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
    @Test func aGoodVerdictIsReadInTheGoalsOrder() throws {
        let verdict = try Judge.verdict(fromAnswer: good, criteria: criteria("c1", "c2"))
        #expect(verdict.criteria.map(\.id) == ["c1", "c2"])
        #expect(verdict.criteria.map(\.met) == [true, false])
        #expect(verdict.criteria[0].evidence == ["The card reads Received this month."])
        #expect(verdict.concerns == ["The filtered label was left alone."])
        let swapped = #"{"criteria":[{"id":"c2","met":true,"evidence":[]},{"id":"c1","met":true,"evidence":[]}],"concerns":[]}"#
        let reordered = try Judge.verdict(fromAnswer: swapped, criteria: criteria("c1", "c2"))
        #expect(reordered.criteria.map(\.id) == ["c1", "c2"])
    }

    @Test func aVerdictInAFenceOrWithAnIntroIsStillRead() throws {
        let wrapped = "Here is my verdict:\n```json\n" + good + "\n```"
        #expect(try Judge.verdict(fromAnswer: wrapped, criteria: criteria("c1", "c2")).criteria.count == 2)
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
            _ = try Judge.verdict(fromAnswer: answer, criteria: criteria("c1", "c2"))
            Issue.record("expected a refusal for \(answer)")
        } catch { #expect("\(error)".contains(why), "\(error)") }
    }

    @Test func evidenceAndConcernsAreBounded() throws {
        let long = String(repeating: "x", count: 1000)
        let many = (0..<20).map { "\"concern \($0)\"" }.joined(separator: ",")
        let answer = """
            {"criteria": [{"id": "c1", "met": true, "evidence": ["\(long)", "b", "c", "d", "e"]}], "concerns": [\(many)]}
            """
        let verdict = try Judge.verdict(fromAnswer: answer, criteria: criteria("c1"))
        #expect(verdict.criteria[0].evidence.count == 3)
        #expect(verdict.criteria[0].evidence[0].count == 300)
        #expect(verdict.concerns.count == 8)
    }
}

@Suite(.processGate) struct JudgeRequestTests {
    private func input(
        screenshots: [String] = [], sizes: [String: PNGSize] = [:], check: Review.Check? = nil,
        verifier: Review.Verifier? = nil, lastTurn: Int = 1
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
            goal: goal, diff: "+new", diffTruncated: false, check: check, checkOutput: nil,
            verifier: verifier, screenshots: screenshots, screenshotSizes: sizes, lastTurn: lastTurn)
    }

    private func verifier(
        turn: Int = 1, ok: Bool = true, reason: String? = nil, skipped: Bool = false, open: Bool = false,
        report: String = "", proof: [String] = []
    ) -> Review.Verifier {
        Review.Verifier(
            turn: turn, ok: ok, reason: reason, skipped: skipped, costUSD: nil, durationMs: nil, report: report,
            proof: proof.map { ProofFile(name: $0, path: "proof/turn-\(turn)/\($0)", sha256: "a", bytes: 1) }, open: open)
    }

    @Test func aVerifierThatRanIsDescribedWithItsReportAsAClaim() throws {
        let ran = verifier(report: "c1: the label reads new.", proof: ["income.png"])
        let prompt = Judge.prompt(for: try input(screenshots: ["income.png"], verifier: ran))
        #expect(prompt.contains("## Verifier\n\nThe verifier finished after turn 1. It left: income.png."))
        #expect(prompt.contains("the verifier's claim, not evidence that any criterion holds"))
        #expect(prompt.contains("```\nc1: the label reads new.\n```"))
        #expect(prompt.contains("- income.png"), "its files are listed as screenshots")
        #expect(!prompt.contains("## Verify step") && !prompt.contains("No verify step ran."))
    }

    @Test(arguments: [
        (false, "boom", false, false, "The verifier failed after turn 1: boom."),
        (false, "no skill file", true, false, "The verifier was skipped for turn 1: no skill file."),
        (false, "started and never recorded an end", false, true, "has no recorded end"),
    ])
    func aVerifierThatDidNotFinishSaysHow(ok: Bool, reason: String, skipped: Bool, open: Bool, says: String) throws {
        let prompt = Judge.prompt(for: try input(verifier: verifier(ok: ok, reason: reason, skipped: skipped, open: open)))
        #expect(prompt.contains(says), "\(prompt)")
        #expect(!prompt.contains("No verify step ran."))
    }

    @Test func anOlderVerifierIsCalledStale() throws {
        let prompt = Judge.prompt(for: try input(verifier: verifier(turn: 1), lastTurn: 2))
        #expect(prompt.contains("The verifier finished after turn 1. This was not the latest turn 2."))
    }

    @Test func theVerifiersReportIsCutAndCannotCloseItsFence() throws {
        let long = "```\n" + String(repeating: "x", count: Judge.verifierReportLimit + 500)
        let prompt = Judge.prompt(for: try input(verifier: verifier(report: long)))
        #expect(prompt.contains("````\n```\nxxx"), "a longer fence than the report's own")
        #expect(!prompt.contains(String(repeating: "x", count: Judge.verifierReportLimit)))
        #expect(prompt.contains("(the report was cut at \(Judge.verifierReportLimit) characters)"))
    }

    @Test func withNoVerifierItSaysNoVerifierRan() throws {
        let prompt = Judge.prompt(for: try input())
        #expect(prompt.contains("## Verifier\n\nNo verifier ran."))
        #expect(!prompt.contains("No verify step ran.") && !prompt.contains("## Verify step"))
    }

    @Test func thePromptCarriesTheGoalTheEvidenceAndTheRules() throws {
        let prompt = Judge.prompt(for: try input(screenshots: ["income.png"], verifier: verifier(proof: ["income.png"])))
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

    @Test func aScreenshotsPixelSizeIsGivenToTheJudge() throws {
        let sizes = ["a.png": PNGSize(width: 2000, height: 1304)]
        let sized = Judge.prompt(for: try input(screenshots: ["a.png", "b.png"], sizes: sizes))
        #expect(sized.contains("- a.png (2000 × 1304 px)"))
        #expect(sized.contains("- b.png\n"), "a size that could not be read is left out")
        #expect(sized.contains("cut off or too small"))
    }

    @Test func aPNGHeaderIsReadAndAnythingElseIsNot() {
        var header = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8)
        header += Data([0, 0, 0x07, 0xD0, 0, 0, 0x05, 0x18])
        #expect(PNGSize.parse(header) == PNGSize(width: 2000, height: 1304))
        #expect(PNGSize.parse(Data("not a png at all, just text".utf8)) == nil)
        #expect(PNGSize.parse(header.prefix(20)) == nil)
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
}

private struct ExpectationFailed: Error {}

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

private func judged(screenshots: Bool = false) async throws -> Judged {
    let fx = try await RunnerFixture()
    let (id, _) = try await acceptedThread(fx)
    if screenshots { try await recordVerifierProof(fx, id, ["home.png": "pixels"]) }
    let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("judge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Judged(fx: fx, id: id, config: try Config.load(from: fx.project.configURL), dir: dir)
}

private let oneCriterion = #"{"criteria": [{"id": "c1", "met": true, "evidence": ["a.txt now says hello."]}], "concerns": []}"#

@Suite(.processGate) struct JudgeServiceTests {
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

    @Test func aMissingClaudeIsAResultAndNoAttemptIsLogged() async throws {
        let j = try await judged()
        let config = try Config.parse("claude_path = \"/no/such/claude\"\n[tools]\navailable = [\"Read\"]\n")
        let result = try await j.fx.service.judge(id: j.id, config: config, environment: ["PATH": "/usr/bin:/bin"])
        #expect(result.verdict == nil && result.failure?.contains("was not found") == true, "\(result.failure ?? "")")
        #expect(try j.fx.events(j.id).filter { $0.kind == .judgeStarted }.isEmpty)
        #expect(try j.fx.events(j.id).last?.kind == .judgeRan)
    }

    @Test func theLoggedArgvIsTheOneThatRan() async throws {
        let j = try await judged()
        let dump = j.dir.appendingPathComponent("dump.json").path
        let env = j.environment("answer=\(try j.file("a.json", oneCriterion))", "dump=\(dump)")
        _ = try await j.fx.service.judge(id: j.id, config: j.config, environment: env)
        let ran = try String(contentsOfFile: dump, encoding: .utf8)
        let started = try #require(try j.fx.events(j.id).first { $0.kind == .judgeStarted })
        guard case .array(let items)? = started.data["argv"] else { throw ExpectationFailed() }
        let logged = items.compactMap(\.stringValue)
        let id = try #require(logged.firstIndex(of: "--session-id").map { logged[$0 + 1] })
        #expect(ran.contains(id), "the session id in judge.started is the one claude was given")
    }

    @Test func withScreenshotsItGetsReadAndRunsInTheirFolder() async throws {
        let j = try await judged(screenshots: true)
        let dump = j.dir.appendingPathComponent("dump.json").path
        let env = j.environment("answer=\(try j.file("a.json", oneCriterion))", "dump=\(dump)")
        _ = try await j.fx.service.judge(id: j.id, config: j.config, environment: env)
        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("--allowedTools") && argv.contains("\"Read\""))
        #expect(argv.contains("home.png"), "the prompt lists the screenshot")
        let folder = OrphanSweeper.realPath(j.fx.project.proofDirectory(j.id, turn: 1))
        #expect(argv.contains(folder), "it runs where the screenshots are")
        #expect(argv.contains("The verifier finished after turn 1. It left: home.png."))
    }

    @Test func theVerifiersRunReachesThePrompt() async throws {
        let j = try await judged()
        let log = try EventLogWriter.open(at: j.fx.project.eventsURL(j.id))
        try await log.append(.verifierStarted, turn: 1, data: ["argv": ["claude"]])
        try await log.append(.verifierEnded, turn: 1, data: ["ok": false, "reason": "timed out", "report": "c1 looked fine"])
        await log.close()
        let dump = j.dir.appendingPathComponent("dump.json").path
        let env = j.environment("answer=\(try j.file("a.json", oneCriterion))", "dump=\(dump)")
        _ = try await j.fx.service.judge(id: j.id, config: j.config, environment: env)
        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("The verifier failed after turn 1: timed out."))
        #expect(argv.contains("c1 looked fine") && argv.contains("the verifier's claim"))
        #expect(!argv.contains("No verify step ran."))
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

@Suite(.processGate) struct JudgeAttemptTests {
    @Test func theJudgeAndItsAttemptCarryTheProviderAndModelItUsed() async throws {
        var j = try await judged()
        j.config.agents.judge = AgentSelection(model: "haiku")
        let answer = try j.file("answer.json", oneCriterion)
        let dump = j.dir.appendingPathComponent("dump.json").path
        _ = try await j.fx.service.judge(
            id: j.id, config: j.config, environment: j.environment("answer=\(answer)", "dump=\(dump)"))

        let events = try j.fx.events(j.id)
        #expect(
            events.suffix(4).map(\.kind) == [.judgeStarted, .agentAttemptStarted, .agentAttemptEnded, .judgeRan])
        for event in events.suffix(4) {
            #expect(event.data["provider"] == "claude" || event.data["attempt"] != nil, "\(event.kind.rawValue)")
        }
        let started = events[events.count - 4], ran = events[events.count - 1]
        #expect(started.data["provider"] == "claude" && started.data["model"] == "haiku")
        #expect(ran.data["provider"] == "claude" && ran.data["model"] == "haiku")
        let attempt = events[events.count - 3], attemptEnd = events[events.count - 2]
        #expect(attempt.data["role"] == "judge" && attempt.data["model"] == "haiku" && attempt.turn == 1)
        #expect(attemptEnd.data["outcome"] == "succeeded" && attemptEnd.data["attempt"] == attempt.data["attempt"])
        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("haiku"), "what was recorded is what was asked of claude")
    }

    @Test func noJudgeModelRecordsNullAndALegacyModelStillApplies() async throws {
        var j = try await judged()
        j.config.judgeModel = "sonnet"
        _ = try await j.fx.service.judge(
            id: j.id, config: j.config, environment: j.environment("answer=\(try j.file("a.json", oneCriterion))"))
        let started = try #require(try j.fx.events(j.id).last { $0.kind == .judgeStarted })
        #expect(started.data["model"] == "sonnet", "judge_model keeps its meaning while [agents.judge] chooses nothing")
        var plain = try await judged()
        plain.config.judgeModel = nil
        plain.config.model = nil
        _ = try await plain.fx.service.judge(
            id: plain.id, config: plain.config,
            environment: plain.environment("answer=\(try plain.file("a.json", oneCriterion))"))
        let none = try #require(try plain.fx.events(plain.id).last { $0.kind == .judgeStarted })
        #expect(none.data["model"] == .null)
    }

    @Test func aKilledJudgeIsClosedBeforeTheNextOneStarts() async throws {
        let j = try await judged()
        let log = try EventLogWriter.open(at: j.fx.project.eventsURL(j.id))
        try await log.append(.judgeStarted, turn: 1, data: ["argv": ["claude"], "provider": "claude", "model": .null])
        try await log.startAttempt(role: "judge", turn: 1, provider: .claude, model: nil)
        await log.close()

        _ = try await j.fx.service.judge(
            id: j.id, config: j.config, environment: j.environment("answer=\(try j.file("a.json", oneCriterion))"))
        let events = try j.fx.events(j.id)
        let kinds = events.suffix(8).map(\.kind.rawValue)
        #expect(
            kinds == [
                "judge.started", "agent.attempt.started", "agent.attempt.ended", "judge.ran",
                "judge.started", "agent.attempt.started", "agent.attempt.ended", "judge.ran",
            ], "\(kinds)")
        let synthetic = events.first { $0.kind == .judgeRan && $0.data["synthetic"] == true }
        #expect(synthetic?.data["reason"] == "interrupted" && synthetic?.data["ok"] == false)
        #expect(events.last?.data["ok"] == true, "the interrupted judge did not count as having judged the turn")
        #expect(try j.fx.contents(j.id).isHealthy)
    }

    @Test func aRefusedLaunchIsARefusedAttemptWithNoProcess() async throws {
        let j = try await judged()
        let config = try Config.parse("claude_path = \"/no/such/claude\"\n[tools]\navailable = [\"Read\"]\n")
        _ = try await j.fx.service.judge(id: j.id, config: config, environment: ["PATH": "/usr/bin:/bin"])
        let events = try j.fx.events(j.id)
        let pair = events.filter { $0.kind == .agentAttemptStarted || $0.kind == .agentAttemptEnded }.suffix(2)
        #expect(pair.first?.data["spawned"] == false && pair.first?.data["role"] == "judge")
        #expect(pair.last?.data["outcome"] == "refused" && pair.last?.data["reason"]?.stringValue?.contains("not found") == true)
        #expect(events.last?.kind == .judgeRan && events.last?.data["provider"] == "claude")
    }
}
