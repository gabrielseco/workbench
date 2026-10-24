import Foundation
import Testing

@testable import WorkbenchCore

private let oneCriterion = #"{"criteria": [{"id": "c1", "met": true, "evidence": ["a.txt now says hello."]}], "concerns": []}"#

private struct CodexJudged {
    var fx: RunnerFixture
    var id: String
    var config: Config
    var codex: FakeCodex

    func judge(
        again: Bool = false, budget: Decimal = Judge.budgetUSD, environment: [String: String]? = nil
    ) async throws -> JudgeResult {
        try await fx.service.judge(
            id: id, config: config, again: again, budget: budget, environment: environment ?? codex.environment())
    }

    var events: [Event] { (try? fx.events(id)) ?? [] }
}

private func codexJudged(
    allowUnpriced: Bool = true, answer: String? = oneCriterion, extraConfig: String = "", screenshots: Bool = false
) async throws -> CodexJudged {
    let fx = try await RunnerFixture(extraConfig: extraConfig)
    let (id, _) = try await acceptedThread(fx)
    if screenshots { try await recordVerifierProof(fx, id, ["home.png": "pixels"]) }
    let codex = try FakeCodex(in: fx)
    if let answer { try codex.put("answer", answer) }
    var config = try Config.load(from: fx.project.configURL)
    config.agents.judge = AgentSelection(provider: .codex, allowUnpriced: allowUnpriced)
    config.agents.executables[.codex] = codex.path
    return CodexJudged(fx: fx, id: id, config: config, codex: codex)
}

@Suite(.processGate) struct JudgeProvidersTests {
    @Test func codexJudgeVerdict() async throws {
        let j = try await codexJudged()
        let result = try await j.judge()
        #expect(result.failure == nil, "\(String(describing: result.failure))")
        #expect(result.verdict?.criteria.map(\.met) == [true])
        let ran = try #require(j.events.last { $0.kind == .judgeRan })
        #expect(ran.data["ok"] == true && ran.data["provider"] == "codex" && ran.data["model"] == .null)
        let kinds = j.events.suffix(4).map(\.kind)
        #expect(kinds == [.judgeStarted, .agentAttemptStarted, .agentAttemptEnded, .judgeRan], "\(kinds)")
        // The answer is a file beside the evidence, not inside the folder Codex reads.
        let answer = j.fx.project.threadDirectory(j.id).appendingPathComponent("judge/turn-1.answer.txt")
        #expect(FileManager.default.fileExists(atPath: answer.path))
        #expect(j.codex.runs == 1)
    }

    @Test func aChosenModelAndEffortReachTheCodexJudge() async throws {
        var j = try await codexJudged()
        j.config.agents.judge.model = "gpt-6-astra"
        j.config.agents.judge.reasoningEffort = "high"
        _ = try await j.judge()
        let call = try #require(j.codex.calls.first)
        #expect(call.contains("-m gpt-6-astra") && call.contains("model_reasoning_effort=\"high\""), "\(call)")
        #expect(j.events.last { $0.kind == .judgeRan }?.data["model"] == "gpt-6-astra")
    }

    @Test func codexJudgeInvocationIsHardened() async throws {
        let j = try await codexJudged(screenshots: true)
        _ = try await j.judge()
        let call = try #require(j.codex.calls.first)
        for flag in ["exec", "-s read-only", "--ephemeral", "--ignore-rules", "approval_policy=\"never\"", "-o ", "-i "] {
            #expect(call.contains(flag), Comment(rawValue: "\(flag) in \(call)"))
        }
        #expect(call.contains("home.png") && !call.contains("workspace-write"))
        let prompt = call.components(separatedBy: " -- ").last ?? ""
        #expect(prompt.contains("attached to this message") && !prompt.contains("Read tool"), "Codex is not told to use Read")
        let started = try #require(j.events.last { $0.kind == .judgeStarted })
        let argv = started.data["argv"]
        #expect("\(String(describing: argv))".contains("--ignore-rules"), "what was recorded is what ran")
        #expect(!"\(String(describing: argv))".contains("Decide, for each criterion"), "no prompt in the log")
    }

    @Test func theCodexAnswerIsNeverInsideTheFolderItReads() async throws {
        for withScreenshots in [false, true] {
            let j = try await codexJudged(screenshots: withScreenshots)
            _ = try await j.judge()
            let call = try #require(j.codex.calls.first)
            let words = call.split(separator: " ").map(String.init)
            let cwd = try #require(words.firstIndex(of: "-C").map { words[$0 + 1] })
            let answer = try #require(words.firstIndex(of: "-o").map { words[$0 + 1] })
            let read = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path + "/"
            #expect(!URL(fileURLWithPath: answer).resolvingSymlinksInPath().path.hasPrefix(read), "\(answer) is inside \(cwd)")
        }
    }

    @Test(arguments: [
        #"{"criteria": [], "concerns": []}"#,
        #"{"criteria": [{"id": "c1", "met": true, "evidence": []}, {"id": "c1", "met": true, "evidence": []}], "concerns": []}"#,
        #"{"criteria": [{"id": "zz", "met": true, "evidence": []}], "concerns": []}"#,
        "not json at all",
    ])
    func codexJudgeRejectsMissingCriterion(answer: String) async throws {
        let j = try await codexJudged(answer: answer)
        let result = try await j.judge()
        #expect(result.verdict == nil)
        #expect(result.failure?.contains("not usable") == true, "\(String(describing: result.failure))")
        #expect(j.events.last?.kind == .judgeRan && j.events.last?.data["ok"] == false)
    }

    @Test func codexJudgeWithoutAnAnswerIsNoVerdict() async throws {
        let j = try await codexJudged(answer: nil)
        let result = try await j.judge()
        #expect(result.verdict == nil && result.failure?.contains("no result") == true, "\(String(describing: result.failure))")
    }

    @Test func codexJudgeNeedsAllowUnpriced() async throws {
        let j = try await codexJudged(allowUnpriced: false)
        let result = try await j.judge()
        #expect(result.verdict == nil && j.codex.runs == 0, "refused before spawn")
        let why = try #require(result.failure)
        #expect(why.contains("allow_unpriced") && why.contains("[agents.judge]"), "\(why)")
        let end = try #require(j.events.last { $0.kind == .agentAttemptEnded })
        #expect(end.data["outcome"] == "refused")
        #expect(j.events.last?.kind == .judgeRan && j.events.last?.data["ok"] == false)
        #expect(!j.events.contains { $0.kind == .judgeStarted }, "nothing was started")
    }

    @Test func claudeJudgeKeepsCap() async throws {
        let fx = try await RunnerFixture()
        let (id, _) = try await acceptedThread(fx)
        var config = try Config.load(from: fx.project.configURL)
        config.agents.judge = AgentSelection(provider: .claude, allowUnpriced: true)
        let answer = fx.repo.deletingLastPathComponent().appendingPathComponent("answer.json")
        try oneCriterion.write(to: answer, atomically: true, encoding: .utf8)
        let result = try await fx.service.judge(
            id: id, config: config, budget: 0.25,
            environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE": "answer=\(answer.path)"])
        #expect(result.verdict != nil)
        let started = try #require(try fx.events(id).last { $0.kind == .judgeStarted })
        let text = "\(String(describing: started.data["argv"]))"
        #expect(text.contains("--max-budget-usd") && text.contains("0.25"), Comment(rawValue: text))
    }

    @Test func codexJudgeCostIsUnknown() async throws {
        let j = try await codexJudged()
        let result = try await j.judge()
        #expect(result.costUSD == nil)
        let ran = try #require(j.events.last { $0.kind == .judgeRan })
        #expect(ran.data["cost_usd"] == nil, "unknown is absent, never 0")
        let state = ThreadState.derive(from: j.events, id: j.id)
        #expect(state.review.judge?.costUSD == nil)
        let report = ReviewReport(
            state: state, title: "T", criteria: [Criterion(id: "c1", text: "t", proof: "cat a.txt")],
            approval: "approved", goalProblem: nil, diff: .unavailable(reason: "x"))
        let line = try #require(report.judgeLines().first)
        #expect(line == "Judge      advisory · turn 1 · cost unknown", Comment(rawValue: line))
    }

    @Test func aCodexJudgeStillRunsOncePerTurn() async throws {
        let j = try await codexJudged()
        _ = try await j.judge()
        await #expect(throws: JudgeRefusal.alreadyJudged(turn: 1)) { _ = try await j.judge() }
        _ = try await j.judge(again: true)
        #expect(j.codex.runs == 2)
    }
}

@Suite(.processGate) struct JudgeCommandTests {
    private func run(_ arguments: [String], _ j: CodexJudged) async throws -> (code: Int32?, text: String) {
        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: arguments,
            environment: [
                "PATH": "\(j.codex.dir.path):/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                "CODEX_FAKE_DIR": j.codex.dir.path,
            ],
            workingDirectory: j.fx.repo, timeout: 120)
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
        return (code, lines.joined(separator: "\n") + (exit?.stderrTail ?? ""))
    }

    @Test func budgetWithCodexJudgeIsUsageError() async throws {
        let j = try await codexJudged(extraConfig: "[agents.judge]\nprovider = \"codex\"\nallow_unpriced = true")
        let withBudget = try await run(["judge", "--budget", "1"], j)
        #expect(withBudget.code == 2 && withBudget.text.contains("--budget has no effect on codex"), "\(withBudget)")
        #expect(j.codex.runs == 0)
        let plain = try await run(["judge"], j)
        #expect(plain.code == 0, "\(plain)")
        #expect(plain.text.contains("no dollar cap") && plain.text.contains("cost unknown"), "\(plain)")
    }
}
