import Foundation
import Testing

@testable import WorkbenchCore

/// A `codex` that emits the JSONL of one turn, edits `a.txt` in the worktree it is started in (its working directory), and
/// records its arguments and prompt per run. `hang`, `crash` and `big` in its folder change what it does.
private struct CodexRun {
    let fx: RunnerFixture
    let dir: URL
    let id: String

    var script: String { dir.appendingPathComponent("codex").path }
    var hasWorktree: Bool {
        FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.appendingPathComponent(id).path)
    }
    func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    func put(_ name: String) throws { try "".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    var runs: Int { Int(read("n")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0 }
    var events: [Event] { (try? fx.events(id)) ?? [] }
    func ended() -> [Event] { events.filter { $0.kind == .turnEnded } }
    func started() -> [Event] { events.filter { $0.kind == .turnStarted } }
    func run(_ directives: String..., feedback: String? = nil, timeout: TimeInterval = 20) async throws -> TurnReport {
        try await fx.runner(id).run(fx.options(directives.joined(separator: ","), feedback: feedback, timeout: timeout))
    }
}

private func fakeCodexScript(_ dir: URL) -> String {
    """
    #!/bin/sh
    D="\(dir.path)"
    n=$(cat "$D/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$D/n"
    for a in "$@"; do p="$a"; done
    printf '%s' "$p" > "$D/prompt_$n"
    echo "$@" > "$D/args_$n"
    pwd -P > "$D/cwd_$n"
    echo '{"type":"thread.started","thread_id":"thread-'$n'"}'
    if [ -f "$D/hang" ]; then sleep 300 & echo $! > "$D/child.pid"; wait; fi
    if [ -f "$D/big" ]; then yes "0123456789012345678901234567890123456789" | head -c 100000 >> a.txt; fi
    echo "turn $n" >> a.txt
    if [ -f "$D/crash" ]; then echo boom >&2; exit 70; fi
    echo '{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"did turn '$n'"}}'
    echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
    """
}

/// A thread whose goal is `spend_policy: timeout_only`, approved while the config picks Codex for coding.
private let skillPath = ".claude/skills/verify/SKILL.md"

private func codexRun(
    extraConfig: String = "", root: String = "", verifier: Bool = false, goalEdit: (String) -> String = { $0 },
    approve: Bool = true
) async throws -> CodexRun {
    let dir = Scratch.url("codex-run", ext: "d")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("codex")
    try fakeCodexScript(dir).write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    let fx = try await RunnerFixture(
        extraConfig: root + "[providers.codex]\nexecutable = \"\(script.path)\"\n[agents.run]\nprovider = \"codex\"\n"
            + (verifier ? "[verifier]\nskill = \"\(skillPath)\"\nmodel = \"sonnet\"\n" : "") + extraConfig)
    if verifier {
        // Committed before the thread exists, so the base commit has the skill.
        let skill = fx.repo.appendingPathComponent(skillPath)
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Verify\n\nLook at the result.\n".write(to: skill, atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "skill"], in: fx.repo)
    }
    let id = try await fx.service.newThread(name: "work", base: "main")
    let url = fx.project.goalURL(id)
    var text = try String(contentsOf: url, encoding: .utf8)
    let fills = [
        ("TODO(workbench): say what should change, in a few sentences.", "Add a greeting to a.txt."),
        ("TODO(workbench): something that can be checked.", "a.txt contains the word hello."),
        ("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "cat a.txt"),
        ("TODO(workbench): what must not change.", "Do not touch other files."),
    ]
    for (placeholder, value) in fills { text = text.replacingOccurrences(of: placeholder, with: value) }
    text = text.replacingOccurrences(
        of: #"budget_usd: [0-9.]+"#, with: "spend_policy: timeout_only", options: .regularExpression)
    text = goalEdit(text)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if approve { try await fx.service.approve(id: id) }
    return CodexRun(fx: fx, dir: dir, id: id)
}

@Suite(.processGate) struct RunProviderTests {
    // MARK: Refusals before anything is touched

    @Test func goalModelOnCodexIsRefused() async throws {
        let c = try await codexRun(goalEdit: {
            $0.replacingOccurrences(of: #"# model: opus[^\n]*"#, with: "model: opus", options: .regularExpression)
        })
        do {
            _ = try await c.run()
            Issue.record("ran with a goal model on Codex")
        } catch let error as RunnerError {
            #expect("\(error)".contains("model") && "\(error)".contains("opus"), "\(error)")
        }
        #expect(c.runs == 0 && !c.hasWorktree)
    }

    @Test func budgetGoalRefusedOnCodex() async throws {
        let c = try await codexRun(goalEdit: { $0.replacingOccurrences(of: "spend_policy: timeout_only", with: "budget_usd: 1") })
        for feedback in [nil, "again"] as [String?] {
            do {
                _ = try await c.run(feedback: feedback)
                Issue.record("ran a budget goal on Codex")
            } catch let error as RunnerError {
                #expect("\(error)".contains("spend_policy: timeout_only") && "\(error)".contains("budget_usd"), "\(error)")
            }
        }
        #expect(c.runs == 0 && !c.hasWorktree)
    }

    @Test func budgetFlagRefusedOnCodex() async throws {
        let c = try await codexRun()
        var options = c.fx.options()
        options.budgetOverride = 1
        await #expect(throws: RunnerError.self) { _ = try await c.fx.runner(c.id).run(options) }
        #expect(c.runs == 0)
    }

    @Test func missingCodexIsRefused() async throws {
        let c = try await codexRun()
        var config = try String(contentsOf: c.fx.project.configURL, encoding: .utf8)
        config = config.replacingOccurrences(of: c.script, with: "/nonexistent/codex")
        try config.write(to: c.fx.project.configURL, atomically: true, encoding: .utf8)
        do {
            _ = try await c.run()
            Issue.record("started without codex")
        } catch let error as RunnerError {
            #expect(error == .agentNotFound(provider: "codex", name: "/nonexistent/codex"), "\(error)")
            #expect("\(error)".contains("/nonexistent/codex") && !"\(error)".contains("claude_path"))
        }
        #expect(!c.hasWorktree)
    }

    @Test func providerSwitchNeedsApproval() async throws {
        let c = try await codexRun()
        // Back to Claude: the goal was approved for Codex.
        var config = try String(contentsOf: c.fx.project.configURL, encoding: .utf8)
        let codex = "[agents.run]\nprovider = \"codex\""
        config = config.replacingOccurrences(of: codex, with: "[agents.run]\nprovider = \"claude\"")
        try config.write(to: c.fx.project.configURL, atomically: true, encoding: .utf8)
        do {
            _ = try await c.run()
            Issue.record("ran on a provider the goal was not approved for")
        } catch let error as RunnerError {
            guard case .codingSettingsChanged(let approved, let now) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(approved.contains("codex") && now.contains("claude"), "\(approved) / \(now)")
        }
        #expect(c.runs == 0)
    }

    // MARK: A turn

    @Test func codexExecutableIsResolved() async throws {
        let c = try await codexRun()
        _ = try await c.run()
        let argv = try #require(c.started().first?.data["argv"])
        guard case .array(let items) = argv, case .string(let first)? = items.first else {
            Issue.record("\(argv)")
            return
        }
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        #expect(resolved(first) == resolved(c.script))
        #expect(!items.contains { if case .string(let s) = $0 { s.contains("claude") } else { false } })
        let args = try #require(c.read("args_1"))
        #expect(args.contains("workspace-write") && args.contains("--ignore-user-config"))
    }

    @Test func codexTurnIsRecorded() async throws {
        let c = try await codexRun()
        let report = try await c.run()
        #expect(report.result == .succeeded && report.summary == "did turn 1", "\(report)")
        let events = c.events
        let started = try #require(events.first { $0.kind == .turnStarted })
        #expect(started.data["provider"] == "codex" && started.data["session_id"] == nil, "a Codex turn names no session")
        #expect(started.data["continuation"] == nil, "the first turn has nothing to continue")
        let attempts = events.filter { $0.kind == .agentAttemptStarted }
        #expect(attempts.count == 1 && attempts.first?.data["role"] == "run" && attempts.first?.data["provider"] == "codex")
        #expect(events.filter { $0.kind == .agentAttemptEnded }.count == 1)
        #expect(!events.contains { $0.kind == .claude }, "no Claude lines from a Codex turn")
        let activity = events.filter { $0.kind == .agentActivity }
        #expect(!activity.isEmpty && activity.allSatisfy { $0.data["provider"] == "codex" })
        let end = try #require(c.ended().first)
        #expect(end.data["result"] == "succeeded" && end.data["session_id"] == nil)
        #expect(c.hasWorktree)
        #expect(c.read("cwd_1")?.contains(c.id) == true, "Codex ran in the thread's worktree")
        // No session is kept: a Codex turn is never resumed.
        #expect(ThreadStore(project: c.fx.project).session(of: c.id) == nil)
    }

    @Test func codexCostStaysUnknown() async throws {
        let c = try await codexRun()
        _ = try await c.run()
        let end = try #require(c.ended().first)
        #expect(end.data["cost_usd"] == nil, "unknown is not recorded as 0")
        let state = ThreadStore(project: c.fx.project).state(of: c.id)
        #expect(state.costUnknown && state.knownCostUSD == nil)
    }

    @Test func denialsStayUnknown() async throws {
        let c = try await codexRun()
        _ = try await c.run()
        let end = try #require(c.ended().first)
        #expect(end.data["permission_denials"] == .null, "Codex reports no refusals: unknown, not 0")
        #expect(ThreadStore(project: c.fx.project).state(of: c.id).review.deniedTools.isEmpty)
    }

    @Test func codexResultsMap() async throws {
        let crash = try await codexRun()
        try crash.put("crash")
        #expect(try await crash.run().result == .failed)

        let hang = try await codexRun()
        try hang.put("hang")
        let slow = try await hang.run(timeout: 1)
        #expect(slow.result == .timedOut, "\(slow.result)")
        #expect(hang.ended().count == hang.started().count, "one turn.ended per turn.started")
    }

    @Test func codexStopLeavesNoChild() async throws {
        let c = try await codexRun()
        try c.put("hang")
        let runner = c.fx.runner(c.id)
        let options = c.fx.options("", timeout: 60)
        let task = Task { try await runner.run(options) }
        for _ in 0..<400 where c.read("child.pid") == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        await runner.stop()
        let report = try await task.value
        #expect(report.result == .stopped, "\(report.result)")
        let text = try #require(c.read("child.pid"))
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<100 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        #expect(gone, "no child is left behind")
        #expect(c.ended().count == 1 && c.events.filter { $0.kind == .agentAttemptEnded }.count == 1)
    }

    @Test func codexRecoveryClosesTheTurn() async throws {
        let c = try await codexRun()
        // A runner killed mid-turn: the turn and its attempt are open.
        let log = try EventLogWriter.open(at: c.fx.project.eventsURL(c.id))
        let agent = ResolvedAgent(provider: .codex, model: nil, allowUnpriced: false)
        try await log.append(.turnStarted, turn: 1, data: .object(ThreadService.agentFields(agent, ["pid": .null])))
        _ = try await AttemptLog(log: log, role: "run", turn: 1, agent: agent).start()
        await log.close()

        _ = try await c.run()
        let events = c.events
        let first = try #require(c.ended().first)
        #expect(first.turn == 1 && first.data["result"] == "interrupted", "\(first.data)")
        let ends = events.filter { $0.kind == .agentAttemptEnded }
        #expect(ends.first?.data["outcome"] == "interrupted" && ends.first?.data["synthetic"] == true)
        #expect(events.filter { $0.kind == .agentAttemptStarted }.count == ends.count, "every attempt closed exactly once")
        #expect(c.ended().count == c.started().count)
    }

    // MARK: Prompts

    @Test func codexFirstPromptCarriesTheRules() async throws {
        let c = try await codexRun()
        _ = try await c.run()
        let prompt = try #require(c.read("prompt_1"))
        #expect(prompt.hasPrefix("You are working in an isolated git worktree"), "the rules head the prompt")
        #expect(prompt.contains("cannot commit") && prompt.contains("Add a greeting to a.txt."))
        #expect(!prompt.contains("Commit your work with clear messages"), "Claude's rules ask for commits; Codex cannot")
        let recorded = try String(contentsOf: c.fx.project.promptURL(c.id, turn: 1), encoding: .utf8)
        #expect(recorded == prompt, "prompts/turn-1.md is what Codex was given")
    }

    @Test func codexFollowUpIsSelfContained() async throws {
        let c = try await codexRun()
        _ = try await c.run()
        let second = try await c.run(feedback: "also handle the empty list")
        #expect(second.result == .succeeded)
        #expect(c.runs == 2, "a fresh process, not a resume")
        let prompt = try #require(c.read("prompt_2"))
        #expect(prompt.contains("Add a greeting to a.txt."), "the goal again")
        #expect(prompt.contains("you do not remember"), "it is told this is a new session")
        #expect(prompt.contains("did turn 1"), "what the previous turn said")
        #expect(prompt.contains("+turn 1") && prompt.contains("a.txt"), "the work so far, as a diff")
        #expect(prompt.contains("also handle the empty list"), "the feedback")
        #expect(prompt.hasPrefix("You are working in an isolated git worktree"))
        let args = try #require(c.read("args_2"))
        #expect(!args.contains("resume"), "Codex is not resumed")
    }

    @Test func continuationIsRecorded() async throws {
        let c = try await codexRun()
        _ = try await c.run()
        _ = try await c.run(feedback: "again")
        let second = try #require(c.started().last)
        guard case .object(let info)? = second.data["continuation"] else {
            Issue.record("\(second.data)")
            return
        }
        #expect(info["mode"] == "fresh_with_context" && info["truncated"] == false)
        #expect(info["diff_bytes"]?.intValue ?? 0 > 0 && info["summary"] == true)

        // A diff over the limit is cut, and the prompt and the record say so.
        let big = try await codexRun()
        try big.put("big")
        _ = try await big.run()
        _ = try await big.run(feedback: "again")
        guard case .object(let cutInfo)? = big.started().last?.data["continuation"] else {
            Issue.record("no record")
            return
        }
        #expect(cutInfo["truncated"] == true && (cutInfo["diff_bytes"]?.intValue ?? 0) <= ThreadRunner.continuationDiffLimit)
        #expect(big.read("prompt_2")?.contains("cut here") == true)
    }

    @Test func aRerunWithoutFeedbackStillGetsTheContext() async throws {
        let c = try await codexRun()
        try c.put("crash")
        #expect(try await c.run().result == .failed, "Codex edited a.txt and then crashed")
        try FileManager.default.removeItem(at: c.dir.appendingPathComponent("crash"))
        // Allowed without --feedback: no turn has succeeded yet. A fresh process must be told where the work stands.
        let again = try await c.run()
        #expect(again.result == .succeeded)
        let prompt = try #require(c.read("prompt_2"))
        #expect(prompt.contains("you do not remember") && prompt.contains("+turn 1"), "the work so far, as a diff")
        #expect(prompt.contains("This is a rerun, not new feedback"))
        guard case .object(let info)? = c.started().last?.data["continuation"] else {
            Issue.record("a rerun records its continuation")
            return
        }
        #expect(info["mode"] == "fresh_with_context" && (info["diff_bytes"]?.intValue ?? 0) > 0)
        let first = try #require(c.started().first)
        #expect(first.data["continuation"] == nil)
    }

    @Test func theAutomaticVerifierRunsOnClaudeNotOnCodex() async throws {
        let c = try await codexRun(root: "check_command = \"true\"\n", verifier: true)
        let report = try await c.run("proof=shot.png")
        #expect(report.result == .succeeded && report.check?.result == .passed)
        let verifier = try #require(report.verifier, "the verifier ran after the passing check")
        #expect(verifier.ok, "\(verifier)")
        #expect(c.runs == 1, "codex was started for the coding turn only, never for the verifier")
        let kinds = c.events.map(\.kind.rawValue).filter { $0.hasPrefix("verifier.") }
        #expect(kinds == ["verifier.started", "verifier.ended"], "\(kinds)")
    }

    @Test func aMissingClaudeSkipsTheVerifierWithTheReason() async throws {
        let c = try await codexRun(root: "check_command = \"true\"\n", verifier: true)
        var config = try String(contentsOf: c.fx.project.configURL, encoding: .utf8)
        config = config.replacingOccurrences(of: FakeClaude.executable.path, with: "/nonexistent/claude")
        try config.write(to: c.fx.project.configURL, atomically: true, encoding: .utf8)
        let report = try await c.run()
        #expect(report.result == .succeeded && report.verifier == nil, "the turn is not failed by a verifier that cannot run")
        let skipped = try #require(c.events.last { $0.kind == .verifierSkipped })
        #expect(skipped.data["reason"]?.stringValue?.contains("claude was not found") == true)
    }

    // MARK: What has no Codex equivalent

    @Test func grantOnCodexIsExplained() async throws {
        let c = try await codexRun()
        let ran = try await workbenchCLI(
            ["grant"], in: c.fx.repo, environment: ["PATH": "/usr/bin:/bin", "HOME": c.fx.repo.path, "USER": NSUserName()])
        #expect(ran.code == 6, "\(ran.code) \(ran.stderr)")
        #expect(ran.stderr.contains("takes no tool grants"), "\(ran.stderr)")
    }

    @Test func planAndVerifierStayOnClaude() async throws {
        // The plan is Claude's whatever `[agents.run]` says: with Codex for coding it still runs the fake claude, and the
        // verifier's code (which resolves `claude_path` itself) is untouched by this change.
        let p = try await planned(extraConfig: "[agents.run]\nprovider = \"codex\"")
        #expect(p.config.resolvedRunAgent().provider == .codex)
        let result = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering("1. Add the greeting."))
        #expect(result.failure == nil && result.ref == "plans/plan-1.md", "\(String(describing: result.failure))")
        let started = try #require(p.events.last { $0.kind == .planStarted })
        #expect(started.data["provider"] == nil || started.data["provider"] == "claude")
    }
}
