import Foundation
import Testing

@testable import WorkbenchCore

/// The plan turn and the PR description and refresh turns with `provider = "codex"`, through the fake `codex`.

private let goodDescription = """
    {"title": "feat(a): add hello", "summary": "Adds a greeting.", "decisions": [], "deviations": []}
    """

private let fourCountries = """
    {"title": "chore: bump four countries", "sections": {"Summary": "Moves four countries to their latest version."}}
    """

private func onCodex(
    _ config: Config, _ role: AgentRole, codex: FakeCodex, model: String? = "gpt-6-astra", allowUnpriced: Bool? = nil
) -> Config {
    var config = config
    let selection = AgentSelection(provider: .codex, model: model, reasoningEffort: "high", allowUnpriced: allowUnpriced)
    if role == .plan { config.agents.plan = selection } else { config.agents.ship = selection }
    config.agents.executables[.codex] = codex.path
    return config
}

private func gone(_ pid: pid_t) async -> Bool {
    for _ in 0..<30 {
        if !FakeClaude.alive(pid) { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return false
}

private func pid(_ codex: FakeCodex, _ name: String) -> pid_t? {
    codex.read(name).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

private final class HolderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    func set(_ new: Int32?) { lock.lock(); value = new; lock.unlock() }
    func get() -> Int32? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Ends the turn as its timeout would (`expire`), but only once the fake has started and reached its hang, so a loaded
/// runner cannot end it before it wrote its pid or set its `trap '' TERM`. `env_1` is the last file it writes before that.
private func expireOnceHanging(_ codex: FakeCodex) -> @Sendable (ProcessRun) -> Void {
    let started = codex.dir.appendingPathComponent("env_1").path
    return { run in
        Task {
            _ = await pollUntil { FileManager.default.fileExists(atPath: started) }
            try? await Task.sleep(nanoseconds: 300_000_000)  // past the two lines between `env` and the trap
            run.expire()
        }
    }
}

/// Stops the turn once it is running.
private let stopSoon: @Sendable (ProcessRun) -> Void = { run in
    Task {
        try? await Task.sleep(nanoseconds: 700_000_000)
        run.stop()
    }
}

// MARK: Plan

private struct CodexPlanned {
    var p: Planned
    var codex: FakeCodex
    var config: Config

    func plan(
        timeout: TimeInterval = Plan.timeout, attach: @escaping @Sendable (ProcessRun) -> Void = { _ in }
    ) async throws -> PlanResult {
        try await p.fx.service.plan(
            id: p.id, config: config, environment: codex.environment(), timeout: timeout, attach: attach)
    }

    /// One `plan.started` (or none when nothing started), the log ends on `plan.ended`, and nothing is left on disk.
    func expectClosed(started: Int = 1) throws {
        let events = p.events
        #expect(events.filter { $0.kind == .planStarted }.count == started && events.last?.kind == .planEnded)
        #expect(try p.fx.contents(p.id).isHealthy)
        let folder = p.fx.service.planDirectory(p.id)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("checkout").path))
        #expect(!FileManager.default.fileExists(atPath: p.fx.service.planScratch(p.id).url.path))
    }
}

private func codexPlanned(allowUnpriced: Bool? = nil) async throws -> CodexPlanned {
    let p = try await planned()
    let codex = try FakeCodex(in: p.fx)
    return CodexPlanned(p: p, codex: codex, config: onCodex(p.config, .plan, codex: codex, allowUnpriced: allowUnpriced))
}

@Suite(.processGate) struct PlanOnCodexTests {
    @Test func aGoodAnswerIsThePlanAndTheTurnIsHardenedAndUnpriced() async throws {
        let c = try await codexPlanned()
        try c.codex.put("answer", aPlan)
        let result = try await c.plan()
        #expect(result.failure == nil && result.ref == "plans/plan-1.md", "\(result.failure ?? "")")
        #expect(result.text?.contains("Add a greeting to a.txt.") == true && result.costUSD == nil)

        let call = try #require(c.codex.calls.first)
        for flag in ["exec", "-s read-only", "--ephemeral", "--ignore-rules", "approval_policy=\"never\"", "-m gpt-6-astra"] {
            #expect(call.contains(flag), Comment(rawValue: "\(flag) in \(call)"))
        }
        #expect(call.contains("model_reasoning_effort=\"high\"") && !call.contains("workspace-write"), "\(call)")
        #expect(c.codex.read("cwds")?.contains("/plan/checkout") == true, "it reads the checkout of the base")

        let started = try #require(c.p.events.last { $0.kind == .planStarted })
        let ended = try #require(c.p.events.last { $0.kind == .planEnded })
        for event in [started, ended] {
            #expect(event.data["provider"] == "codex" && event.data["model"] == "gpt-6-astra")
        }
        #expect(ended.data["ok"] == true && ended.data["cost_usd"] == nil, "no cost is recorded, not even 0")
        #expect("\(String(describing: started.data["argv"]))".contains("--ignore-rules"), "what ran is what was logged")
        try c.expectClosed()
    }

    @Test(arguments: [("   \n", "codex left no answer"), (nil, "codex left no answer")] as [(String?, String)])
    func anAnswerThatIsNoPlanIsAFailedPlan(answer: String?, why: String) async throws {
        let c = try await codexPlanned()
        if let answer { try c.codex.put("answer", answer) }
        let result = try await c.plan()
        #expect(result.text == nil && result.failure?.contains(why) == true, "\(result.failure ?? "")")
        #expect(c.p.events.last?.data["ok"] == false && c.p.events.last?.data["provider"] == "codex")
        try c.expectClosed()
    }

    @Test func aCrashingCodexIsAFailedPlan() async throws {
        let c = try await codexPlanned()
        try c.codex.put("answer", aPlan)
        try c.codex.put("crash", "")
        let result = try await c.plan()
        #expect(result.text == nil && result.failure?.contains("status 70") == true, "\(result.failure ?? "")")
        try c.expectClosed()
    }

    @Test func aMissingCodexIsAFailedPlanThatStartedNothing() async throws {
        var c = try await codexPlanned()
        c.config.agents.executables[.codex] = "/nowhere/codex"
        let result = try await c.plan()
        #expect(result.failure?.contains("was not found") == true, "\(result.failure ?? "")")
        #expect(c.codex.runs == 0)
        try c.expectClosed(started: 0)
    }

    @Test func allowUnpricedFalseRefusesItBeforeAnythingStarts() async throws {
        let c = try await codexPlanned(allowUnpriced: false)
        try c.codex.put("answer", aPlan)
        let result = try await c.plan()
        #expect(result.text == nil && c.codex.runs == 0)
        let why = try #require(result.failure)
        #expect(why.contains("allow_unpriced") && why.contains("[agents.plan]"), "\(why)")
        try c.expectClosed(started: 0)
    }

    @Test func aHangingCodexEndsAtTheTimeout() async throws {
        let c = try await codexPlanned()
        try c.codex.put("hang", "")
        let result = try await c.plan(timeout: 2)
        #expect(result.failure?.contains("did not answer within 2s") == true, "\(result.failure ?? "")")
        try c.expectClosed()
    }

    @Test func stoppingACodexPlanEndsItAndSaysSo() async throws {
        let c = try await codexPlanned()
        try c.codex.put("hang", "")
        let result = try await c.plan(attach: stopSoon)
        #expect(result.failure?.contains("stopped") == true, "\(result.failure ?? "")")
        try c.expectClosed()
    }

    @Test func aCodexThatIgnoresTermIsKilled() async throws {
        let c = try await codexPlanned()
        try c.codex.put("hang", "")
        try c.codex.put("ignore_term", "")
        let result = try await c.plan(attach: expireOnceHanging(c.codex))
        #expect(result.failure?.contains("did not answer") == true, "\(result.failure ?? "")")
        let codex = try #require(pid(c.codex, "pid"))
        defer { kill(codex, SIGKILL) }
        #expect(await gone(codex), "the process is ended with the plan")
        try c.expectClosed()
    }

    @Test func theLoggedDirectoryIsTheOneItRanIn() async throws {
        let c = try await codexPlanned()
        try c.codex.put("answer", aPlan)
        _ = try await c.plan()
        let ran = try #require(c.codex.read("cwds")?.split(separator: "\n").first.map(String.init))
        for kind in [EventKind.planStarted, .planEnded] {
            let event = try #require(c.p.events.last { $0.kind == kind })
            guard case .array(let argv)? = event.data["argv"] else {
                Issue.record("no argv in \(kind)")
                continue
            }
            let args = argv.compactMap(\.stringValue)
            let at = try #require(args.firstIndex(of: "-C"), "\(args)")
            // The checkout is gone by now, so its parent (the plan folder) is what resolves the system's symlinks.
            let logged = URL(fileURLWithPath: args[at + 1])
            let resolved = OrphanSweeper.realPath(logged.deletingLastPathComponent()) + "/" + logged.lastPathComponent
            #expect(resolved == ran, "\(kind): \(args)")
        }
    }

    @Test func anAnswerFolderAKilledPlanLeftIsClearedByTheNextCommandAndOneInUseIsNot() async throws {
        let c = try await codexPlanned()
        let scratch = c.p.fx.service.planScratch(c.p.id)
        try scratch.prepare()
        try "half an answer".write(to: scratch.answer, atomically: true, encoding: .utf8)
        // Killed after `plan.started`: the next command closes the plan and clears what it left.
        do {
            let log = try EventLogWriter.open(at: c.p.fx.project.eventsURL(c.p.id))
            try await log.append(.planStarted, turn: 0, data: ["argv": [], "goal_hash": "h", "base_commit": "b"])
            await log.close()
        }
        try await c.p.fx.service.withLog(c.p.id) { _ in }
        #expect(FileManager.default.fileExists(atPath: scratch.answer.path), "this process still owns it")
        #expect(c.p.events.last?.kind == .planEnded, "the plan is closed either way")

        let dead: [String: Any] = ["pid": 999_999, "started_seconds": 1, "started_micros": 1]
        try JSONSerialization.data(withJSONObject: dead).write(to: scratch.url.appendingPathComponent("owner.json"))
        try await c.p.fx.service.withLog(c.p.id) { _ in }
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path), "its Workbench is gone, so is plan/answer/")
    }

    @Test func aRecoveredEndKeepsTheStartsProviderAndModel() async throws {
        let c = try await codexPlanned()
        do {
            let log = try EventLogWriter.open(at: c.p.fx.project.eventsURL(c.p.id))
            try await log.append(
                .planStarted, turn: 0,
                data: ["argv": [], "goal_hash": "h", "base_commit": "b", "provider": "codex", "model": "gpt-6-astra"])
            await log.close()  // killed here
        }
        try await c.p.fx.service.withLog(c.p.id) { _ in }
        let ended = try #require(c.p.events.last)
        #expect(ended.kind == .planEnded && ended.data["synthetic"] == true)
        #expect(ended.data["provider"] == "codex" && ended.data["model"] == "gpt-6-astra" && ended.data["goal_hash"] == "h")
        #expect(try c.p.fx.contents(c.p.id).isHealthy)
    }

    @Test func aChildCodexLeftBehindIsEnded() async throws {
        let c = try await codexPlanned()
        try c.codex.put("answer", aPlan)
        try c.codex.put("leave_child", "")
        let result = try await c.plan()
        #expect(result.failure == nil, "\(result.failure ?? "")")
        let child = try #require(pid(c.codex, "child_pid"))
        defer { kill(child, SIGKILL) }
        #expect(await gone(child), "what it left in the checkout is ended")
        try c.expectClosed()
    }
}

// MARK: Description

private struct CodexDescribed {
    var fx: RunnerFixture
    var plan: ShipPlan
    var codex: FakeCodex
    var config: Config

    func describe(
        timeout: TimeInterval = PRDescriber.timeout, attach: @escaping @Sendable (ProcessRun) -> Void = { _ in }
    ) async throws -> PRDescribeResult {
        try await fx.service.describePR(
            plan: plan, config: config, environment: codex.environment(), timeout: timeout, attach: attach)
    }

    var scratch: URL { fx.service.prTurnScratch(plan.id).url }

    /// The turn left a `pr.described` that failed and nothing behind.
    func expectFellBack(_ result: PRDescribeResult, because why: String) throws {
        #expect(result.description == nil && result.fallback?.contains(why) == true, "\(result.fallback ?? "")")
        let event = try #require(try fx.events(plan.id).last)
        #expect(event.kind == .prDescribed && event.data["ok"] == false && event.data["provider"] == "codex")
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "the scratch folder is removed")
        #expect(try fx.contents(plan.id).isHealthy)
    }
}

private func codexDescribed(allowUnpriced: Bool? = nil) async throws -> CodexDescribed {
    let fx = try await RunnerFixture()
    let (id, _) = try await acceptedThread(fx)
    _ = try await addOrigin(fx)
    let gh = try FakeGH(in: fx)
    let plan = try await fx.service.shipPreflight(id: id, gh: gh.runner)
    let codex = try FakeCodex(in: fx)
    let config = onCodex(try Config.load(from: fx.project.configURL), .ship, codex: codex, allowUnpriced: allowUnpriced)
    return CodexDescribed(fx: fx, plan: plan, codex: codex, config: config)
}

@Suite(.processGate) struct DescribeOnCodexTests {
    @Test func aGoodAnswerIsTheDescriptionAndIsRecordedWithItsAgent() async throws {
        let d = try await codexDescribed()
        try d.codex.put("answer", goodDescription)
        let result = try await d.describe()
        #expect(result.fallback == nil && result.description?.title == "feat(a): add hello", "\(result.fallback ?? "")")

        let call = try #require(d.codex.calls.first)
        for flag in ["-s read-only", "--ignore-rules", "approval_policy=\"never\"", "-m gpt-6-astra", "--skip-git-repo-check"] {
            #expect(call.contains(flag), Comment(rawValue: "\(flag) in \(call)"))
        }
        #expect(call.contains("model_reasoning_effort=\"high\""))
        let event = try #require(try d.fx.events(d.plan.id).last)
        #expect(event.kind == .prDescribed && event.data["ok"] == true)
        #expect(event.data["provider"] == "codex" && event.data["model"] == "gpt-6-astra" && event.data["cost_usd"] == nil)
    }

    @Test func itRunsInAnEmptyFolderOutsideTheRepositoryThatIsGoneAfterwards() async throws {
        let d = try await codexDescribed()
        try d.codex.put("answer", goodDescription)
        _ = try await d.describe()
        let cwd = try #require(d.codex.read("cwds")?.split(separator: "\n").first.map(String.init))
        #expect(d.codex.read("tree_1") == "", "nothing of the checkout is in the folder it runs in")
        let repo = OrphanSweeper.realPath(d.fx.repo)
        #expect(!cwd.hasPrefix(repo + "/") && cwd != repo, "\(cwd) is inside \(repo)")
        #expect(!cwd.hasPrefix(OrphanSweeper.realPath(d.plan.worktree)), "\(cwd)")
        #expect(!FileManager.default.fileExists(atPath: cwd), "\(cwd) is removed when the turn ends")
        #expect(!FileManager.default.fileExists(atPath: d.scratch.path))
    }

    @Test func anInvalidAnswerFallsBackToTheGoal() async throws {
        let d = try await codexDescribed()
        try d.codex.put("answer", "not json at all")
        try d.expectFellBack(try await d.describe(), because: "not a JSON object")
    }

    @Test func aCrashingCodexFallsBack() async throws {
        let d = try await codexDescribed()
        try d.codex.put("answer", goodDescription)
        try d.codex.put("crash", "")
        try d.expectFellBack(try await d.describe(), because: "status 70")
    }

    @Test func aMissingCodexFallsBack() async throws {
        var d = try await codexDescribed()
        d.config.agents.executables[.codex] = "/nowhere/codex"
        try d.expectFellBack(try await d.describe(), because: "was not found")
        #expect(d.codex.runs == 0)
    }

    @Test func allowUnpricedFalseFallsBackWithoutStartingCodex() async throws {
        let d = try await codexDescribed(allowUnpriced: false)
        try d.codex.put("answer", goodDescription)
        try d.expectFellBack(try await d.describe(), because: "[agents.ship]")
        #expect(d.codex.runs == 0)
    }

    @Test func aHangingCodexFallsBackAtTheTimeout() async throws {
        let d = try await codexDescribed()
        try d.codex.put("hang", "")
        try d.expectFellBack(try await d.describe(timeout: 1), because: "did not answer within 1s")
    }

    @Test func stoppingTheTurnFallsBackAndSaysSo() async throws {
        let d = try await codexDescribed()
        try d.codex.put("hang", "")
        try d.expectFellBack(try await d.describe(attach: stopSoon), because: "stopped")
    }

    @Test func aCodexThatIgnoresTermIsKilled() async throws {
        let d = try await codexDescribed()
        try d.codex.put("hang", "")
        try d.codex.put("ignore_term", "")
        try d.expectFellBack(try await d.describe(attach: expireOnceHanging(d.codex)), because: "did not answer")
        let codex = try #require(pid(d.codex, "pid"))
        defer { kill(codex, SIGKILL) }
        #expect(await gone(codex))
    }

    @Test func aChildCodexLeftBehindIsEnded() async throws {
        let d = try await codexDescribed()
        try d.codex.put("answer", goodDescription)
        try d.codex.put("leave_child", "")
        let result = try await d.describe()
        #expect(result.fallback == nil, "\(result.fallback ?? "")")
        let child = try #require(pid(d.codex, "child_pid"))
        defer { kill(child, SIGKILL) }
        #expect(await gone(child), "what it left in the scratch folder is ended")
        #expect(!FileManager.default.fileExists(atPath: d.scratch.path))
    }

    @Test(arguments: [nil, "crash"] as [String?])
    func theTurnHoldsTheThreadAndLetsGoAfterwardsAlsoOnAFailure(failure: String?) async throws {
        let d = try await codexDescribed()
        try d.codex.put("answer", goodDescription)
        if let failure { try d.codex.put(failure, "") }
        let service = d.fx.service
        let id = d.plan.id
        let seen = HolderBox()
        _ = try await d.describe(attach: { _ in seen.set(service.runnerPID(id: id)) })
        #expect(seen.get() == getpid(), "stop reaches this process while the turn runs")
        #expect(!FileManager.default.fileExists(atPath: d.fx.project.runnerURL(id).path))
        #expect(service.runnerPID(id: id) == nil)
    }

    @Test func aFolderAKilledWorkbenchLeftIsClearedByTheNextCommandAndOneInUseIsNot() async throws {
        let d = try await codexDescribed()
        let scratch = d.fx.service.prTurnScratch(d.plan.id)
        try scratch.prepare()
        try await d.fx.service.withLog(d.plan.id) { _ in }
        #expect(FileManager.default.fileExists(atPath: scratch.url.path), "this process still owns it")

        let dead: [String: Any] = ["pid": 999_999, "started_seconds": 1, "started_micros": 1]
        try JSONSerialization.data(withJSONObject: dead).write(to: scratch.url.appendingPathComponent("owner.json"))
        try await d.fx.service.withLog(d.plan.id) { _ in }
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path), "its Workbench is gone")
    }
}

// MARK: Refresh

private struct CodexRefresh {
    var fx: RunnerFixture
    var thread: UpdateThread
    var plan: ShipPlan
    var codex: FakeCodex
    var config: Config

    func propose() async throws -> PRRefreshResult {
        try await fx.service.proposePRRefresh(plan: plan, config: config, environment: codex.environment())
    }

    func expectFellBack(_ result: PRRefreshResult, because why: String) throws {
        #expect(result.proposal == nil && result.fallback?.contains(why) == true, "\(result.fallback ?? "")")
        let event = try #require(try fx.events(thread.id).last)
        #expect(event.kind == .prRefreshed && event.data["ok"] == false && event.data["provider"] == "codex")
        #expect(!FileManager.default.fileExists(atPath: fx.service.prTurnScratch(thread.id).url.path))
    }
}

private func codexRefresh() async throws -> CodexRefresh {
    let fx = try await RunnerFixture()
    let thread = try await acceptedUpdateThread(fx)
    let gh = try FakeGH(in: fx)
    let head = try await shipOut(["rev-parse", "HEAD"], thread.worktree, fx)
    let item: [String: Any] = [
        "number": 12, "url": "https://github.com/o/r/pull/12", "headRefName": "feature/pr", "baseRefName": "main",
        "headRefOid": head, "title": "chore: bump five countries", "body": sampleBody,
    ]
    try gh.put("list", String(decoding: try JSONSerialization.data(withJSONObject: [item]), as: UTF8.self))
    let plan = try await fx.service.shipPreflight(id: thread.id, gh: gh.runner)
    let codex = try FakeCodex(in: fx)
    let config = onCodex(try Config.load(from: fx.project.configURL), .ship, codex: codex)
    return CodexRefresh(fx: fx, thread: thread, plan: plan, codex: codex, config: config)
}

@Suite(.processGate) struct RefreshOnCodexTests {
    @Test func aGoodAnswerIsAProposalRecordedWithItsAgent() async throws {
        let r = try await codexRefresh()
        try r.codex.put("answer", fourCountries)
        let result = try await r.propose()
        let proposal = try #require(result.proposal, "\(result.fallback ?? "")")
        #expect(proposal.titleChanged && proposal.changes.map(\.heading) == ["## Summary"])
        let event = try #require(try r.fx.events(r.thread.id).last)
        #expect(event.kind == .prRefreshed && event.data["ok"] == true && event.data["stage"] == "proposed")
        #expect(event.data["provider"] == "codex" && event.data["model"] == "gpt-6-astra")
        #expect(r.codex.read("tree_1") == "", "the refresh turn sees nothing of the checkout either")
        #expect(!FileManager.default.fileExists(atPath: r.fx.service.prTurnScratch(r.thread.id).url.path))
    }

    @Test func anInvalidAnswerLeavesThePullRequestAlone() async throws {
        let r = try await codexRefresh()
        try r.codex.put("answer", #"{"title": "t", "sections": {"No such section": "x"}}"#)
        try r.expectFellBack(try await r.propose(), because: "not a section")
    }

    @Test func aCrashingCodexLeavesThePullRequestAlone() async throws {
        let r = try await codexRefresh()
        try r.codex.put("crash", "")
        try r.expectFellBack(try await r.propose(), because: "status 70")
    }

    @Test func aMissingCodexLeavesThePullRequestAlone() async throws {
        var r = try await codexRefresh()
        r.config.agents.executables[.codex] = "/nowhere/codex"
        try r.expectFellBack(try await r.propose(), because: "was not found")
    }
}

// MARK: Logs from before the fields

@Suite(.processGate) struct ReadOnlyEventsWithoutAgentTests {
    @Test func eventsWithoutProviderAndModelStillReplay() async throws {
        let p = try await planned()
        do {
            let log = try EventLogWriter.open(at: p.fx.project.eventsURL(p.id))
            try await log.append(.planStarted, turn: 0, data: ["argv": [], "goal_hash": "h", "base_commit": "b"])
            try await log.append(
                .planEnded, turn: 0,
                data: ["ok": false, "goal_hash": "h", "base_commit": "b", "reason": "x", "cost_usd": 0.25])
            try await log.append(.prDescribed, data: ["ok": true, "argv": [], "title": "feat: t"])
            try await log.append(.prRefreshed, data: ["stage": "proposed", "ok": false, "reason": "r", "argv": []])
            await log.close()
        }
        let events = p.events
        let state = ThreadState.derive(from: events, id: p.id)
        #expect(state.plan?.ok == false && state.plan?.failure == "x" && state.planCostUSD == 0.25)
        #expect(try p.fx.contents(p.id).isHealthy)
        for event in events.suffix(4) { #expect(!LogFormatter.describe(event).isEmpty) }
    }
}

// MARK: Claude unchanged

@Suite struct ReadOnlyClaudeCommandTests {
    @Test func theDescriptionCommandIsTheOneItWas() throws {
        for extra in ["", "safe_mode = false\n", "[agents.ship]\nmodel = \"haiku\"\nreasoning_effort = \"low\"\n"] {
            let config = try Config.parse(extra + "[tools]\navailable = [\"Read\"]\n")
            let agent = config.resolvedShipAgent
            let session = UUID()
            let request = ReadOnlyRequest(
                prompt: "the prompt", workingDirectory: URL(fileURLWithPath: "/tmp"), model: agent.model,
                budget: PRDescriber.budgetUSD, timeout: 1, reasoningEffort: agent.reasoningEffort, tools: .none,
                sessionID: session)
            let built = ClaudeReadOnlyAgent(config: config, environment: [:]).arguments(for: request)
            #expect(built == PRDescriber.arguments(config: config, prompt: "the prompt", sessionID: session), "\(extra)")
        }
    }

    @Test func theLoggedSessionIsTheOneThatRuns() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\"]\n")
        let agent = ClaudeReadOnlyAgent(config: config, environment: [:])
        let request = ReadOnlyRequest(
            prompt: "p", workingDirectory: URL(fileURLWithPath: "/tmp"), model: nil, budget: 1, timeout: 1)
        #expect(agent.shownArguments(for: request) == PRDescriber.displayArguments(agent.arguments(for: request)))
    }
}
