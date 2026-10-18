import Foundation
import Testing

@testable import WorkbenchCore

private struct Planned {
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

    func answering(_ text: String, _ more: String...) throws -> [String: String] {
        let answer = try file("a-\(UUID().uuidString).txt", text)
        return ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE": (["answer=\(answer)"] + more).joined(separator: ",")]
    }

    var events: [Event] { (try? fx.events(id)) ?? [] }
}

private func planned(extraConfig: String = "") async throws -> Planned {
    let fx = try await RunnerFixture(extraConfig: extraConfig)
    let id = try await fx.approvedThread()
    let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("plan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Planned(fx: fx, id: id, config: try Config.load(from: fx.project.configURL), dir: dir)
}

private final class PlanBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

private let aPlan = "## Approach\n\nAdd a greeting to a.txt.\n\n## Files\n\n- a.txt: add hello.\n"

@Suite struct PlanArgumentsTests {
    private func request() -> ReadOnlyRequest {
        ReadOnlyRequest(
            prompt: "the prompt", workingDirectory: URL(fileURLWithPath: "/tmp"), model: "opus", budget: 1, timeout: 60)
    }

    @Test func theTurnIsReadOnlyByItsToolListAndOwnsItsSession() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\", \"Edit\", \"Write\", \"Bash\"]\nallowed = [\"Edit\"]\n")
        let agent = ClaudeReadOnlyAgent(config: config, environment: [:])
        let args = agent.arguments(for: request())
        let tools = try #require(args.firstIndex(of: "--tools"))
        #expect(Array(args[(tools + 1)...].prefix(3)) == ["Read", "Grep", "Glob"])
        let allowed = try #require(args.firstIndex(of: "--allowedTools"))
        #expect(Array(args[(allowed + 1)...].prefix(3)) == ["Read", "Grep", "Glob"])
        for banned in ["Bash", "Edit", "Write", "--resume", "--permission-mode", "--disallowedTools"] {
            #expect(!args.contains(banned), "\(banned)")
        }
        #expect(args.contains("--restricted") && args.contains("--safe-mode") && args.contains("--session-id"))
        #expect(args.contains("--max-budget-usd") && args.suffix(2) == ["--", "the prompt"])
        let model = try #require(args.firstIndex(of: "--model"))
        #expect(args[model + 1] == "opus")
    }

    @Test func safeModeIsOnEvenWhenTheProjectTurnedItOffForRuns() throws {
        let config = try Config.parse("safe_mode = false\n[tools]\navailable = [\"Read\"]\n")
        let args = ClaudeReadOnlyAgent(config: config, environment: [:]).arguments(for: request())
        #expect(args.contains("--safe-mode") && args.contains("--disable-slash-commands"))
    }

    @Test func theLoggedCommandHasNoPrompt() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\"]\n")
        let shown = ClaudeReadOnlyAgent(config: config, environment: [:]).shownArguments(for: request())
        #expect(!shown.contains("the prompt") && !shown.contains("--"))
    }

    @Test func thePromptCarriesTheGoalAndTheRulesOfTheRole() throws {
        let goal = try GoalFile.parse(
            """
            ---
            id: g
            title: Greet
            status: draft
            base: main
            budget_usd: 1
            turn_timeout_min: 5
            ---

            ## Request

            Add a greeting.

            ## Criteria

            - [c1] a.txt says hello
              - proof: cat a.txt

            ## Out of scope

            - other files
            """
        ).goal
        let prompt = Plan.prompt(for: PlanInput(goal: goal, baseCommit: "0123456789abcdef", instructions: nil))
        for part in ["Add a greeting.", "[c1] a.txt says hello", "other files", "0123456789ab", "do not ask questions", "Risks"] {
            #expect(prompt.contains(part), "\(part)")
        }
    }

    @Test func storedTextIsCleanedCutOnACharacterAndNeverEmpty() {
        #expect(Plan.stored(from: "  \n ") == nil)
        let secret = Plan.stored(from: "see /Users/dev/proj/x.swift and https://bob:hunter22@host/r")
        #expect(secret?.text.contains("/Users/dev") == false && secret?.text.contains("hunter22") == false)
        let long = Plan.stored(from: String(repeating: "é", count: Plan.textLimit))
        #expect(long?.truncated == true && long?.text.hasSuffix(Plan.cutMarker) == true)
        #expect(long?.text.contains("\u{FFFD}") == false, "no half character")
        #expect(Plan.stored(from: "short")?.truncated == false)
    }
}

@Suite struct PlanServiceTests {
    @Test func aPlanIsRecordedFromStartToEndAndKeptAsAFile() async throws {
        let p = try await planned()
        let dump = p.dir.appendingPathComponent("dump.json").path
        let turns = p.events.filter { $0.kind == .turnStarted }.count
        let result = try await p.fx.service.plan(
            id: p.id, config: p.config, environment: try p.answering(aPlan, "dump=\(dump)"))
        #expect(result.failure == nil && result.ref == "plans/plan-1.md" && result.costUSD == 0.001)

        let events = p.events
        let started = try #require(events.last { $0.kind == .planStarted })
        let ended = try #require(events.last { $0.kind == .planEnded })
        #expect(started.seq < ended.seq && events.filter { $0.kind == .planStarted }.count == 1)
        #expect(ended.data["ok"] == true && ended.data["plan_ref"] == "plans/plan-1.md")
        #expect(ended.data["goal_hash"] == started.data["goal_hash"] && ended.data["base_commit"] == started.data["base_commit"])
        #expect(ended.data["bytes"]?.intValue == aPlan.utf8.count)
        #expect(ended.data["sha256"]?.stringValue?.count == 64)
        #expect(started.data["argv"].map { "\($0)" }?.contains("a-") != true, "the prompt is not logged")
        #expect(events.filter { $0.kind == .turnStarted }.count == turns, "not a numbered turn")
        #expect(try p.fx.contents(p.id).isHealthy)

        let file = p.fx.project.threadDirectory(p.id).appendingPathComponent("plans/plan-1.md")
        let stored = try String(contentsOf: file, encoding: .utf8)
        #expect(stored.contains("Add a greeting to a.txt."))
        let cwd = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(cwd.contains("plan/checkout"), "it runs in the throwaway checkout")
        #expect(!FileManager.default.fileExists(atPath: p.fx.service.planDirectory(p.id).appendingPathComponent("checkout").path))
        let registered = try await p.fx.git.run(["worktree", "list", "--porcelain"], in: p.fx.repo)
        #expect(!registered.stdout.contains("plan/checkout"), "git keeps no registration of it")

        let state = ThreadState.derive(from: events, id: p.id)
        #expect(state.plan?.ok == true && state.plan?.ref == "plans/plan-1.md" && state.plan?.failure == nil)
    }

    @Test func theModelIsTheFlagThenPlanModelThenModel() async throws {
        func model(_ extra: String, flag: String? = nil) async throws -> String? {
            let p = try await planned(extraConfig: extra)
            let dump = p.dir.appendingPathComponent("dump.json").path
            _ = try await p.fx.service.plan(
                id: p.id, config: p.config, model: flag, environment: try p.answering(aPlan, "dump=\(dump)"))
            let argv = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dump))) as? [String: Any])["argv"]
            let list = try #require(argv as? [String])
            return list.firstIndex(of: "--model").map { list[$0 + 1] }
        }
        #expect(try await model("model = \"sonnet\"\nplan_model = \"opus\"\n", flag: "haiku") == "haiku")
        #expect(try await model("model = \"sonnet\"\nplan_model = \"opus\"\n") == "opus")
        #expect(try await model("model = \"sonnet\"\n") == "sonnet")
        #expect(try await model("") == nil)
    }

    @Test func aDraftOrChangedGoalIsRefusedAndSpendsNothing() async throws {
        let first = try await RunnerFixture()
        let draft = try await first.service.newThread(name: "draft", base: "main")
        do {
            _ = try await first.service.plan(id: draft, config: try Config.load(from: first.project.configURL))
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .goalNotApproved(.draft)) }
        #expect(try first.events(draft).allSatisfy { $0.kind != .planStarted && $0.kind != .planEnded })

        let fx = try await RunnerFixture()
        let config = try Config.load(from: fx.project.configURL)
        let id = try await fx.approvedThread("edited")
        let url = fx.project.goalURL(id)
        let edited = try String(contentsOf: url, encoding: .utf8) + "\n- another thing\n"
        try edited.write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try await fx.service.plan(id: id, config: config)
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .goalNotApproved(.stale)) }
        #expect(try fx.events(id).allSatisfy { $0.kind != .planStarted && $0.kind != .planEnded })
    }

    @Test func itRunsOncePerApprovedGoalUnlessAskedAgain() async throws {
        let p = try await planned()
        _ = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering(aPlan))
        do {
            _ = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering(aPlan))
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .alreadyPlanned) }
        let again = try await p.fx.service.plan(id: p.id, config: p.config, again: true, environment: try p.answering(aPlan))
        #expect(again.ref == "plans/plan-2.md")
        #expect(p.events.filter { $0.kind == .planEnded }.count == 2)
    }

    @Test func aBadModelAndALiveRunAreRefused() async throws {
        let p = try await planned()
        do {
            _ = try await p.fx.service.plan(id: p.id, config: p.config, model: "--bad model")
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .invalidModel("--bad model")) }
        let me = getpid()
        let started = try #require(ProcessTree.member(for: me))
        let info: [String: Any] = ["pid": me, "started_seconds": started.startSeconds, "started_micros": started.startMicros]
        try JSONSerialization.data(withJSONObject: info).write(to: p.fx.project.runnerURL(p.id))
        do {
            _ = try await p.fx.service.plan(id: p.id, config: p.config)
            Issue.record("expected a refusal")
        } catch let error as ThreadServiceError { #expect(error == .running(pid: me)) }
    }

    @Test(arguments: [
        ("   \n", "", "the plan was empty"),
        (aPlan, "exit=1", "status 1"),
    ])
    func aFailedPlanIsRecordedWithItsReason(answer: String, exit: String, why: String) async throws {
        let p = try await planned()
        let result = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering(answer, exit))
        #expect(result.text == nil && result.failure?.contains(why) == true, "\(result.failure ?? "")")
        let ended = try #require(p.events.last)
        #expect(ended.kind == .planEnded && ended.data["ok"] == false && ended.data["plan_ref"] == nil)
        #expect(ThreadState.derive(from: p.events, id: p.id).plan?.failure?.contains(why) == true)
        #expect(try p.fx.contents(p.id).isHealthy)
        // A failure does not use up the goal's plan.
        _ = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering(aPlan))
    }

    @Test func aLongPlanIsCutAndPathsAndCredentialsAreScrubbed() async throws {
        let p = try await planned()
        let text = "Edit /Users/dev/secret/place/x.swift; token https://bob:hunter22@host/r\n"
            + String(repeating: "word ", count: 6000)
        let result = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering(text))
        let stored = try #require(result.text)
        #expect(result.truncated && stored.hasSuffix(Plan.cutMarker))
        #expect(stored.utf8.count <= Plan.textLimit + Plan.cutMarker.utf8.count + 1)
        #expect(!stored.contains("/Users/dev") && !stored.contains("hunter22"))
        let ended = try #require(p.events.last)
        #expect(ended.data["truncated"] == true)
    }

    @Test func stoppingEndsThePlanAndRecordsWhy() async throws {
        let p = try await planned()
        let result = try await p.fx.service.plan(
            id: p.id, config: p.config, environment: p.environment("hang-after=1"),
            attach: { run in
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    run.stop()
                }
            })
        #expect(result.text == nil && result.failure?.contains("stopped") == true, "\(result.failure ?? "")")
        #expect(p.events.last?.kind == .planEnded && p.events.last?.data["ok"] == false)
        #expect(try p.fx.contents(p.id).isHealthy)
        #expect(!FileManager.default.fileExists(atPath: p.fx.service.planDirectory(p.id).appendingPathComponent("checkout").path))
    }

    @Test(arguments: ["hang-after=1", "exit=70"])
    func aHangingOrFailingClaudeStillEndsThePlan(directive: String) async throws {
        let p = try await planned()
        let result = try await p.fx.service.plan(
            id: p.id, config: p.config, environment: p.environment(directive), timeout: 2)
        #expect(result.text == nil && result.failure != nil, "\(result.failure ?? "")")
        let events = p.events
        #expect(events.filter { $0.kind == .planStarted }.count == 1 && events.last?.kind == .planEnded)
        #expect(try p.fx.contents(p.id).isHealthy)
        #expect(!FileManager.default.fileExists(atPath: p.fx.service.planDirectory(p.id).appendingPathComponent("checkout").path))
    }

    @Test func aClaudeThatIgnoresTermAndLeavesAChildLeavesNothingBehind() async throws {
        let p = try await planned()
        let pidfile = p.dir.appendingPathComponent("grandchild.pid").path
        let ready = p.dir.appendingPathComponent("ready").path
        let result = try await p.fx.service.plan(
            id: p.id, config: p.config,
            environment: p.environment("hang-after=1", "ignore-term", "grandchild=\(pidfile)", "ready=\(ready)"),
            timeout: 2)
        #expect(result.failure != nil)
        let pidText = try String(contentsOfFile: pidfile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let child = try #require(Int32(pidText))
        defer { kill(child, SIGKILL) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!FakeClaude.alive(child), "the tree is ended with the plan")
    }

    @Test func aPlanThatStartedAndNeverEndedShowsAsInterruptedAndIsClosedByTheNextOne() async throws {
        let p = try await planned()
        do {
            let log = try EventLogWriter.open(at: p.fx.project.eventsURL(p.id))
            try await log.append(.planStarted, turn: 0, data: ["argv": [], "goal_hash": "h", "base_commit": "b"])
            await log.close()  // killed here
        }
        let state = ThreadState.derive(from: p.events, id: p.id)
        #expect(state.plan?.ok == false && state.plan?.failure?.contains("never recorded") == true)

        _ = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering(aPlan))
        let ends = p.events.filter { $0.kind == .planEnded }
        #expect(ends.count == 2 && ends[0].data["reason"] == "interrupted" && ends[0].data["synthetic"] == true)
        #expect(ends[0].data["goal_hash"] == "h" && ends[1].data["ok"] == true)
        #expect(try p.fx.contents(p.id).isHealthy)
    }

    @Test func anInterruptedPlanIsClosedBeforeAnyRefusalAndByARun() async throws {
        let p = try await planned()
        func orphan() async throws {
            let log = try EventLogWriter.open(at: p.fx.project.eventsURL(p.id))
            try await log.append(.planStarted, turn: 0, data: ["argv": [], "goal_hash": "h", "base_commit": "b"])
            await log.close()  // killed here
        }
        let leftover = p.fx.service.planDirectory(p.id).appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        // A plan that is then refused (the goal changed) still closes the old one and clears what it left.
        try await orphan()
        let url = p.fx.project.goalURL(p.id)
        try (try String(contentsOf: url, encoding: .utf8) + "\n- another\n").write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try await p.fx.service.plan(id: p.id, config: p.config)
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .goalNotApproved(.stale)) }
        #expect(p.events.last?.kind == .planEnded && p.events.last?.data["reason"] == "interrupted")
        #expect(!FileManager.default.fileExists(atPath: leftover.path))

        // So does a run, which is not a plan command at all.
        try await orphan()
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try await p.fx.service.approve(id: p.id)
        _ = try await p.fx.runner(p.id).run()
        let ends = p.events.filter { $0.kind == .planEnded }
        #expect(ends.count == 2 && ends.allSatisfy { $0.data["reason"] == "interrupted" })
        #expect(!FileManager.default.fileExists(atPath: leftover.path))

        // And any other command that opens the log (here, the judge).
        try await orphan()
        let verdict = #"{"criteria": [{"id": "c1", "met": true, "evidence": ["ok"]}], "concerns": []}"#
        _ = try await p.fx.service.judge(id: p.id, config: p.config, environment: try p.answering(verdict))
        #expect(p.events.filter { $0.kind == .planEnded }.count == 3)
        #expect(try p.fx.contents(p.id).isHealthy)
    }

    @Test func aCheckoutThatCannotBeRemovedIsReportedNotHidden() async throws {
        struct Locking: ReadOnlyAgent {
            func unavailable() -> String? { nil }
            func shownArguments(for request: ReadOnlyRequest) -> [String] { ["stub"] }
            func run(_ request: ReadOnlyRequest, attach: @Sendable (ProcessRun) -> Void) async -> ReadOnlyAnswer {
                // A read-only directory with a file in it cannot be emptied, by git or by hand.
                let locked = request.workingDirectory.appendingPathComponent("locked")
                try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
                try? "x".write(to: locked.appendingPathComponent("f"), atomically: true, encoding: .utf8)
                chmod(locked.path, 0o555)
                return ReadOnlyAnswer(text: "A plan.", costUSD: nil, failure: nil)
            }
        }
        let p = try await planned()
        let checkout = p.fx.service.planDirectory(p.id).appendingPathComponent("checkout")
        defer {
            chmod(checkout.appendingPathComponent("locked").path, 0o755)
            try? FileManager.default.removeItem(at: checkout)
        }
        let result = try await p.fx.service.plan(id: p.id, config: p.config, agent: Locking())
        #expect(result.text != nil, "the plan itself is kept")
        #expect(result.warning?.contains("could not be removed") == true, "\(result.warning ?? "")")
        #expect(p.events.last?.data["warning"] != nil)
    }

    @Test func aLeftoverCheckoutFromAKilledPlanIsClearedBeforeTheNextOne() async throws {
        let p = try await planned()
        let leftover = p.fx.service.planDirectory(p.id).appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "junk".write(to: leftover.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)
        let result = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering(aPlan))
        #expect(result.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func aUnknownBaseIsAFailedPlanNotACrash() async throws {
        let fx = try await RunnerFixture()
        let config = try Config.load(from: fx.project.configURL)
        let id = try await fx.approvedThread("ghost", base: "no-such-branch")
        let result = try await fx.service.plan(id: id, config: config)
        #expect(result.text == nil && result.failure != nil)
        let ended = try #require(try fx.events(id).last)
        #expect(ended.kind == .planEnded && ended.data["ok"] == false)
        #expect(try fx.events(id).allSatisfy { $0.kind != .planStarted }, "nothing was started, so nothing is left open")
    }

    @Test func aMissingClaudeIsAFailedPlan() async throws {
        let p = try await planned(extraConfig: "")
        var config = p.config
        config.claudePath = "/no/such/claude"
        let result = try await p.fx.service.plan(id: p.id, config: config, environment: ["PATH": "/usr/bin:/bin"])
        #expect(result.failure?.contains("was not found") == true)
        #expect(p.events.last?.kind == .planEnded && p.events.allSatisfy { $0.kind != .planStarted })
    }

    @Test func whilePlanningThisProcessHoldsTheThreadAndLetsGoAfterwards() async throws {
        let p = try await planned()
        let service = p.fx.service
        let id = p.id
        let seen = PlanBox<Int32?>(nil)
        _ = try await service.plan(
            id: id, config: p.config, environment: try p.answering(aPlan), attach: { _ in seen.set(service.runnerPID(id: id)) })
        #expect(seen.get() == getpid())
        #expect(service.runnerPID(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: p.fx.project.runnerURL(id).path))
    }

    @Test func twoPlansCannotSpendOnTheSameThreadAtOnce() async throws {
        let p = try await planned()
        let held = try EventLogWriter.open(at: p.fx.project.eventsURL(p.id))
        do {
            _ = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering(aPlan))
            Issue.record("expected the thread to be busy")
        } catch let error as PlanRefusal { #expect(error == .busy) }
        await held.close()
    }

    @Test func anyAgentCanAnswerBehindTheSeam() async throws {
        struct Stub: ReadOnlyAgent {
            func unavailable() -> String? { nil }
            func shownArguments(for request: ReadOnlyRequest) -> [String] { ["stub", "--read-only"] }
            func run(_ request: ReadOnlyRequest, attach: @Sendable (ProcessRun) -> Void) async -> ReadOnlyAnswer {
                let name = request.workingDirectory.lastPathComponent
                return ReadOnlyAnswer(text: "From the stub, for \(name).", costUSD: 0.5, failure: nil)
            }
        }
        let p = try await planned()
        let result = try await p.fx.service.plan(id: p.id, config: p.config, agent: Stub())
        #expect(result.text?.contains("From the stub, for checkout.") == true && result.costUSD == 0.5)
        let started = try #require(p.events.last { $0.kind == .planStarted })
        #expect(started.data["argv"] == ["stub", "--read-only"])
    }
}
