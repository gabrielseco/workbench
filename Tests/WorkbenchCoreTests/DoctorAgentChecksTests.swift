import Foundation
import Testing

@testable import WorkbenchCore

private let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"

private func config(_ text: String) throws -> Config { try Config.parse(text + tools) }

private func documentedKeys(_ name: String) throws -> Set<String> {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/spec/cli-json.md")
    let line = try #require(
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("\(name) keys:") })
    return Set(
        line.dropFirst("\(name) keys:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
}

private func issues(_ agents: [DoctorAgent], _ role: AgentRole) -> [DoctorAgentIssue] {
    agents.first { $0.role == role }?.issues ?? []
}

/// Executables that exist, so only what a test sets up is missing.
private let present = "claude_path = \"/bin/sh\"\n[providers.codex]\nexecutable = \"/bin/sh\"\n"

private func doctorGoal(model: String?) -> DoctorGoal {
    DoctorGoal(thread: "g-1-x", spend: .hardCap(1), turnTimeoutMin: 30, model: model, approvedFor: nil)
}

@Suite struct DoctorAgentChecksTests {
    @Test func policyWithoutControls() throws {
        let cfg = try config(present)
        var claude = ClaudeProvider(config: cfg).capabilities
        claude.policies = [.readOnlyEvidence]
        let found = Doctor.agents(cfg, searchPath: "/bin") { $0 == .claude ? claude : CodexProvider().capabilities }
        let run = issues(found, .run).filter { $0.kind == "policy_without_controls" }
        #expect(run.count == 1 && run[0].severity == .problem && run[0].message.contains("scopedCoding"), "\(run)")
        #expect(
            issues(found, .judge).allSatisfy { $0.kind != "policy_without_controls" }, "read-only is still verified")
        // Codex has no controls for coding: asked to code, it is reported from its own capabilities.
        let real = Doctor.agents(cfg, searchPath: "/bin")
        #expect(
            real.flatMap(\.issues).allSatisfy { $0.kind != "policy_without_controls" },
            "the shipped pairs are all verified")
    }

    @Test func missingExecutable() throws {
        let cfg = try config("claude_path = \"/nowhere/claude\"\n[providers.codex]\nexecutable = \"/bin/sh\"")
        let found = Doctor.agents(cfg, searchPath: "/bin")
        let missing = found.flatMap(\.issues).filter { $0.kind == "missing_executable" }
        #expect(
            Set(missing.map(\.role)) == [.run, .judge, .ship, .plan],
            "claude is run, judge, ship and plan; codex is present: \(missing)")
        #expect(missing.allSatisfy { $0.severity == .problem && $0.message.contains("/nowhere/claude") })
        // A bare name is looked up on the environment's PATH, without a shell.
        let bare = try config("claude_path = \"/bin/sh\"\n[providers.codex]\nexecutable = \"nothing-here\"")
        let review = issues(Doctor.agents(bare, searchPath: "/bin"), .review)
        #expect(review.contains { $0.kind == "missing_executable" && $0.message.contains("nothing-here") })
    }

    @Test func budgetOnUncappedAdapter() throws {
        let cfg = try config(present)
        var uncapped = ClaudeProvider(config: cfg).capabilities
        uncapped.hardDollarCap = false
        let goal = DoctorGoal(
            thread: "g-1-x", spend: .hardCap(Decimal(string: "0.50")!), turnTimeoutMin: 30, model: nil, approvedFor: nil)
        let found = Doctor.agents(cfg, searchPath: "/bin", goal: goal) { _ in uncapped }
        let run = issues(found, .run).filter { $0.kind == "budget_without_cap" }
        #expect(run.count == 1 && run[0].message.contains("g-1-x") && run[0].message.contains("0.5"), "\(run)")
        #expect(issues(found, .judge).allSatisfy { $0.kind != "budget_without_cap" }, "only coding has a goal budget")
        let capped = Doctor.agents(cfg, searchPath: "/bin", goal: goal)
        #expect(capped.flatMap(\.issues).allSatisfy { $0.kind != "budget_without_cap" }, "claude enforces it")
        #expect(
            Doctor.agents(cfg, searchPath: "/bin", goal: nil) { _ in uncapped }.flatMap(\.issues).allSatisfy {
                $0.kind != "budget_without_cap"
            })
    }

    @Test func budgetWithoutCapNamesTimeoutOnly() throws {
        let cfg = try config(present)
        var uncapped = ClaudeProvider(config: cfg).capabilities
        uncapped.hardDollarCap = false
        let goal = doctorGoal(model: nil)
        let found = Doctor.agents(cfg, searchPath: "/bin", goal: goal) { _ in uncapped }
        let message = try #require(issues(found, .run).first { $0.kind == "budget_without_cap" }).message
        #expect(message.contains("spend_policy: timeout_only") && message.contains("approve it again"), "\(message)")
    }

    @Test func timeoutOnlyGoalHasNoBudgetProblem() throws {
        let cfg = try config(present)
        var uncapped = ClaudeProvider(config: cfg).capabilities
        uncapped.hardDollarCap = false
        var goal = doctorGoal(model: nil)
        goal.spend = .timeoutOnly
        let found = Doctor.agents(cfg, searchPath: "/bin", goal: goal) { _ in uncapped }
        #expect(found.flatMap(\.issues).allSatisfy { $0.kind != "budget_without_cap" })
        #expect(goal.spendLine == "no dollar cap: bounded by 30 min per turn")
    }

    @Test func theGoalsModelWinsOverTheConfigs() throws {
        let cfg = try config(present + "\n[agents.run]\nmodel = \"haiku\"\n")
        func runModel(_ goal: DoctorGoal?) -> String? {
            Doctor.agents(cfg, searchPath: "/bin", goal: goal).first { $0.role == .run }?.resolved?.model
        }
        #expect(runModel(nil) == "haiku")
        #expect(runModel(doctorGoal(model: "opus")) == "opus")
        #expect(runModel(doctorGoal(model: nil)) == "haiku")
    }

    @Test func unconfinedReadsStated() throws {
        let found = Doctor.agents(try config(present), searchPath: "/bin")
        let review = issues(found, .review).filter { $0.kind == "unconfined_reads" }
        #expect(review.count == 1 && review[0].severity == .note && review[0].message.contains("outside the checkout"))
        #expect(issues(found, .judge).allSatisfy { $0.kind != "unconfined_reads" }, "claude confines reads")
        #expect(found.flatMap(\.problems).isEmpty, "a stated limit is not a problem")
    }

    @Test(arguments: [AgentRole.ship, .plan])
    func unconfinedReadsStatedForACodexDescriptionOrPlan(role: AgentRole) throws {
        let cfg = try config(present + "\n[agents.\(role.rawValue)]\nprovider = \"codex\"\n")
        let found = Doctor.agents(cfg, searchPath: "/bin")
        let note = issues(found, role).filter { $0.kind == "unconfined_reads" }
        #expect(note.count == 1 && note[0].severity == .note && note[0].message.contains("outside"), "\(note)")
        #expect(found.flatMap(\.problems).isEmpty, "a stated limit is not a problem")
        let onClaude = Doctor.agents(try config(present), searchPath: "/bin")
        #expect(issues(onClaude, role).allSatisfy { $0.kind != "unconfined_reads" }, "claude confines reads")
    }

    /// A key under [providers.*] or [agents.*] is read by a resolver or refused when the config loads; a key this
    /// table does not know fails here, so a new one cannot be added without saying which.
    @Test func everyKeyHonouredOrReported() throws {
        let providerValues: [String: String] = ["executable": "\"/bin/echo\""]
        for key in AgentsConfig.providerKeys {
            let value = try #require(providerValues[key], "[providers.*] key '\(key)' has no case in this test")
            let cfg = try config("[providers.claude]\n\(key) = \(value)")
            #expect(cfg.executable(for: .claude) == "/bin/echo", "\(key) is read")
        }
        let selectionValues: [String: String] = ["model": "\"haiku\"", "reasoning_effort": "\"high\"", "allow_unpriced": "true"]
        for role in AgentRole.allCases {
            for key in AgentsConfig.selectionKeys {
                // A provider other than the role's default: refused where no adapter exists yet, read where one does.
                let other = role == .review ? "\"claude\"" : "\"codex\""
                let value = try #require(
                    key == "provider" ? other : selectionValues[key], "[agents.*] key '\(key)' has no case in this test"
                )
                let providerLine = role == .goal && key != "provider" ? "provider = \"claude\"\n" : ""
                let text = "[agents.\(role.rawValue)]\n\(providerLine)\(key) = \(value)"
                let cfg: Config
                do { cfg = try config(text) } catch is ConfigError { continue }  // reported
                let baseline = try config(role == .goal ? "[agents.goal]\nprovider = \"claude\"" : "")
                #expect(
                    resolved(cfg, role) != resolved(baseline, role),
                    "\(role.rawValue) \(key) is neither read nor refused")
            }
        }
    }

    @Test func allowUnpricedNoteDescribesBehaviour() throws {
        let cfg = try config(present + "[agents.judge]\nallow_unpriced = true\n[agents.review]\nallow_unpriced = true")
        let found = Doctor.agents(cfg, searchPath: "/bin")
        let judge = issues(found, .judge).filter { $0.kind == "setting_unused" }
        #expect(judge.count == 1 && judge[0].message.contains("enforces a dollar limit"))
        let review = issues(found, .review).filter { $0.kind == "setting_unused" }
        #expect(review.count == 1 && review[0].message.contains("is the default"), "\(review)")
        #expect(issues(found, .review).contains { $0.kind == "timeout_only" }, "true still says what bounds it")
        let unused = try config(
            "claude_path = \"/bin/sh\"\n[providers.codex]\nexecutable = \"/bin/sh\"\n[agents.review]\nprovider = \"codex\""
        )
        #expect(issues(Doctor.agents(unused, searchPath: "/bin"), .review).allSatisfy { $0.kind != "setting_unused" })
    }

    /// Codex chosen for goal drafting, the judge, the review, the PR description or the plan: unset and `true` run
    /// timeout-only and say what bounds them; `false` is the problem that names the key.
    @Test(arguments: [AgentRole.goal, .judge, .review, .ship, .plan])
    func codexEvaluationWithAndWithoutTheKey(role: AgentRole) throws {
        let table = "[agents.\(role.rawValue)]\nprovider = \"codex\"\n"
        let timeout = Int(try #require(role.evaluationTimeout))
        for line in ["", "allow_unpriced = true\n"] {
            let found = issues(Doctor.agents(try config(present + table + line), searchPath: "/bin"), role)
            #expect(found.allSatisfy { $0.kind != "unpriced_not_allowed" }, "\(role) \(line): \(found)")
            let note = try #require(found.first { $0.kind == "timeout_only" }, "\(role) \(line): \(found)")
            #expect(note.severity == .note && note.message.contains("no dollar cap") && note.message.contains("\(timeout) s"))
        }
        let forbidden = Doctor.agents(try config(present + table + "allow_unpriced = false\n"), searchPath: "/bin")
        let problems = issues(forbidden, role).filter { $0.kind == "unpriced_not_allowed" }
        #expect(problems.count == 1 && problems[0].severity == .problem, "\(problems)")
        #expect(problems[0].message.contains("allow_unpriced") && problems[0].message.contains("[agents.\(role.rawValue)]"))
        #expect(issues(forbidden, role).allSatisfy { $0.kind != "timeout_only" })
        #expect(forbidden.flatMap(\.problems).count == 1)
    }

    @Test func aProviderWithACapIsNeitherRefusedNorTimeoutOnly() throws {
        let claude = try config(present + "[agents.review]\nprovider = \"claude\"\nallow_unpriced = false")
        let found = issues(Doctor.agents(claude, searchPath: "/bin"), .review)
        #expect(found.allSatisfy { $0.kind != "unpriced_not_allowed" && $0.kind != "timeout_only" }, "\(found)")
        let stage = try config(
            present + "[review]\nstages = [\"pr-review\", \"design\"]\n[review.stage.design]\n"
                + "prompt = \"d.md\"\nprovider = \"claude\"")
        #expect(issues(Doctor.agents(stage, searchPath: "/bin"), .review).allSatisfy { $0.kind != "unpriced_not_allowed" })
    }

    @Test func aListedStageOnCodexIsTimeoutOnlyUnlessForbidden() throws {
        let text =
            present + "[agents.review]\nprovider = \"claude\"\n[review]\nstages = [\"pr-review\", \"design\"]\n"
            + "[review.stage.design]\nprompt = \"d.md\"\nprovider = \"codex\"\n"
        let unset = issues(Doctor.agents(try config(text), searchPath: "/bin"), .review)
        #expect(unset.allSatisfy { $0.kind != "unpriced_not_allowed" }, "\(unset)")
        let note = try #require(unset.first { $0.kind == "timeout_only" }, "\(unset)")
        #expect(note.message.contains("design") && note.message.contains("no dollar cap"))
        let forbidden = issues(Doctor.agents(try config(text + "allow_unpriced = false\n"), searchPath: "/bin"), .review)
        let found = forbidden.filter { $0.kind == "unpriced_not_allowed" }
        #expect(found.count == 1 && found[0].severity == .problem, "\(found)")
        #expect(found[0].message.contains("design") && found[0].message.contains("[review.stage.design]"))
    }

    @Test func aStageThatAllowsWhatTheForbiddenReviewDoesNotStillSaysItHasNoCap() throws {
        let text =
            present + "[agents.review]\nprovider = \"codex\"\nallow_unpriced = false\n[review]\n"
            + "stages = [\"pr-review\", \"design\"]\n[review.stage.design]\nprompt = \"d.md\"\nallow_unpriced = true\n"
        let found = issues(Doctor.agents(try config(text), searchPath: "/bin"), .review)
        #expect(found.filter { $0.kind == "unpriced_not_allowed" }.count == 1, "\(found)")
        let note = try #require(found.first { $0.kind == "timeout_only" }, "\(found)")
        #expect(note.message.contains("design") && note.message.contains("no dollar cap"))
    }

    @Test func legacyCodexReviewIsNotProblem() throws {
        let plain = try config(present)
        #expect(issues(Doctor.agents(plain, searchPath: "/bin"), .review).allSatisfy { $0.kind != "unpriced_not_allowed" })
        let alias = try config(present + "[review.stage.pr-review]\nreviewer = \"codex\"")
        #expect(issues(Doctor.agents(alias, searchPath: "/bin"), .review).allSatisfy { $0.kind != "unpriced_not_allowed" })
    }

    private func resolved(_ cfg: Config, _ role: AgentRole) -> ResolvedAgent? {
        switch role {
        case .goal: cfg.resolvedGoalAgent
        case .run: cfg.resolvedRunAgent()
        case .judge: cfg.resolvedJudgeAgent()
        case .review: cfg.resolvedReviewAgent()
        case .ship: cfg.resolvedShipAgent
        case .plan: cfg.resolvedPlanAgent()
        }
    }
}

@Suite struct DoctorVerdictTests {
    private func report(setup: DoctorStep.Outcome, cleanup: String?) -> DoctorReport {
        DoctorReport(
            base: "main", claude: nil, claudePath: "claude", model: nil, bashAvailable: true, checkPattern: nil,
            setup: DoctorStep(command: "make", outcome: setup, tail: "", hint: ""),
            check: DoctorStep(command: nil, outcome: .notDeclared, tail: "", hint: ""), cleanupProblem: cleanup)
    }

    @Test func aCleanupFailureComesBeforeAStop() {
        #expect(report(setup: .stopped, cleanup: "remove it by hand").verdict == .cleanupFailed("remove it by hand"))
        #expect(report(setup: .stopped, cleanup: nil).verdict == .stopped)
        #expect(report(setup: .failed(how: "exit 1"), cleanup: nil).verdict == .stepsFailed)
        #expect(report(setup: .passed, cleanup: nil).verdict == .passed)
    }
}

@Suite(.processGate) struct DoctorAgentChecksCLITests {
    private func doctor(_ extraConfig: String, json: Bool) async throws -> (CLIRan, [String: Any]?) {
        let fx = try await RunnerFixture(extraConfig: extraConfig)
        let ran = try await workbenchCLI(
            ["doctor"] + (json ? ["--json"] : []), in: fx.repo,
            environment: ["PATH": "/usr/bin:/bin", "HOME": fx.repo.path, "USER": NSUserName()])
        guard json else { return (ran, nil) }
        return (ran, try JSONSerialization.jsonObject(with: Data(ran.stdout.utf8)) as? [String: Any])
    }

    @Test func jsonShape() async throws {
        let (ran, object) = try await doctor(
            "[agents.run]\nmodel = \"opus\"\n[agents.ship]\nmodel = \"haiku\"\nreasoning_effort = \"low\"", json: true)
        #expect(ran.code == 0, "\(ran.stdout) \(ran.stderr)")
        #expect(ran.stdout.split(separator: "\n").count == 1 && ran.stderr.isEmpty, "one object, nothing else")
        let doc = try #require(object)
        #expect(Set(doc.keys) == (try documentedKeys("doctor")))
        #expect(doc["v"] as? Int == 1 && doc["passed"] as? Bool == true)
        let agents = try #require(doc["agents"] as? [[String: Any]])
        #expect(agents.compactMap { $0["role"] as? String } == ["goal", "run", "judge", "review", "ship", "plan"])
        #expect(agents[0]["provider"] is NSNull && agents[0]["note"] as? String == "goal drafting stays manual")
        #expect(agents[1]["provider"] as? String == "claude" && agents[1]["model"] as? String == "opus")
        #expect(doc["model"] as? String == "opus", "the top-level model is [agents.run]'s")
        #expect(agents[4]["provider"] as? String == "claude" && agents[4]["model"] as? String == "haiku")
        #expect(agents[4]["reasoning_effort"] as? String == "low" && (agents[4]["issues"] as? [Any])?.isEmpty == true)
        #expect(agents[5]["provider"] as? String == "claude" && agents[5]["model"] is NSNull)
        #expect(agents[5]["reasoning_effort"] is NSNull)
        #expect(agents[3]["provider"] as? String == "codex" && agents[3]["model"] is NSNull)
        let review = try #require(agents[3]["issues"] as? [[String: Any]])
        #expect(review.contains { $0["kind"] as? String == "unconfined_reads" && $0["severity"] as? String == "note" })
        #expect(doc["thread"] is NSNull && doc["approved_for"] is NSNull, "no active thread")
        #expect((doc["setup"] as? [String: Any])?["result"] as? String == "not_declared")
    }

    @Test func approvedForOfTheActiveThread() async throws {
        let fx = try await RunnerFixture(extraConfig: "[agents.run]\nmodel = \"opus\"")
        let id = try await fx.approvedThread()
        let ran = try await workbenchCLI(
            ["doctor", "--json"], in: fx.repo,
            environment: ["PATH": "/usr/bin:/bin", "HOME": fx.repo.path, "USER": NSUserName()])
        let doc = try #require(JSONSerialization.jsonObject(with: Data(ran.stdout.utf8)) as? [String: Any])
        #expect(doc["thread"] as? String == id)
        #expect((doc["approved_for"] as? [String: Any])?["model"] as? String == "opus")
        let text = try await workbenchCLI(
            ["doctor"], in: fx.repo, environment: ["PATH": "/usr/bin:/bin", "HOME": fx.repo.path, "USER": NSUserName()])
        #expect(text.stdout.contains("approved: \(id) for claude, model opus"), "\(text.stdout)")
    }

    @Test func exitCodesUnchanged() async throws {
        for json in [false, true] {
            let passing = try await doctor("", json: json)
            #expect(passing.0.code == 0, "json \(json): \(passing.0.stderr)")
            let failing = try await doctor("check_command = \"false\"", json: json)
            #expect(
                failing.0.code == 1, "json \(json): a failed check exits 1: \(failing.0.stdout) \(failing.0.stderr)")
            if json {
                #expect(
                    failing.1?["passed"] as? Bool == false && failing.1?["error"] == nil,
                    "the report, not an error object")
                #expect((failing.1?["check"] as? [String: Any])?["result"] as? String == "failed")
            }
        }
    }

    @Test func problemsDoNotFailDoctorByThemselves() async throws {
        let (ran, object) = try await doctor("[providers.codex]\nexecutable = \"/nowhere/codex\"", json: true)
        #expect(ran.code == 0, "a missing executable is reported, the declared steps decide: \(ran.stderr)")
        let doc = try #require(object)
        #expect(doc["passed"] as? Bool == true)
        let problems = try #require(doc["problems"] as? [[String: Any]])
        #expect(
            problems.contains { $0["kind"] as? String == "missing_executable" && $0["role"] as? String == "review" })
        let text = try await doctor("[providers.codex]\nexecutable = \"/nowhere/codex\"", json: false)
        #expect(text.0.stdout.contains("problem: codex is not installed"), "\(text.0.stdout)")
    }

    @Test func anUnsetAllowUnpricedIsANoteAndFalseIsAProblem() async throws {
        let judge = "[providers.codex]\nexecutable = \"/bin/sh\"\n[agents.judge]\nprovider = \"codex\"\n"
        func judgeIssues(_ doc: [String: Any]?) -> [[String: Any]] {
            let agents = doc?["agents"] as? [[String: Any]] ?? []
            return agents.first { $0["role"] as? String == "judge" }?["issues"] as? [[String: Any]] ?? []
        }
        let (_, unset) = try await doctor(judge, json: true)
        #expect(judgeIssues(unset).contains { $0["kind"] as? String == "timeout_only" && $0["severity"] as? String == "note" })
        let problems = unset?["problems"] as? [[String: Any]] ?? []
        #expect(!problems.contains { $0["kind"] as? String == "unpriced_not_allowed" }, "\(problems)")
        let text = try await doctor(judge, json: false)
        #expect(text.0.stdout.contains("note: codex has no dollar cap"), "\(text.0.stdout)")
        let (_, forbidden) = try await doctor(judge + "allow_unpriced = false\n", json: true)
        let refused = forbidden?["problems"] as? [[String: Any]] ?? []
        #expect(refused.contains { $0["kind"] as? String == "unpriced_not_allowed" && $0["role"] as? String == "judge" })
    }

    @Test func shipAndPlanOnCodexShowTheirAgentAndTheMissingCap() async throws {
        let tables =
            "[providers.codex]\nexecutable = \"/bin/sh\"\n[agents.ship]\nprovider = \"codex\"\nmodel = \"gpt-6\"\n"
            + "reasoning_effort = \"low\"\n[agents.plan]\nprovider = \"codex\"\nreasoning_effort = \"high\"\n"
        let (ran, object) = try await doctor(tables, json: true)
        #expect(ran.code == 0, "\(ran.stderr)")
        let agents = try #require(object?["agents"] as? [[String: Any]])
        let ship = try #require(agents.first { $0["role"] as? String == "ship" })
        let plan = try #require(agents.first { $0["role"] as? String == "plan" })
        #expect(ship["provider"] as? String == "codex" && ship["model"] as? String == "gpt-6")
        #expect(ship["reasoning_effort"] as? String == "low")
        #expect(plan["provider"] as? String == "codex" && plan["model"] is NSNull)
        #expect(plan["reasoning_effort"] as? String == "high")
        for agent in [ship, plan] {
            let found = agent["issues"] as? [[String: Any]] ?? []
            #expect(found.contains { $0["kind"] as? String == "timeout_only" && $0["severity"] as? String == "note" })
        }
        #expect((object?["problems"] as? [[String: Any]] ?? []).isEmpty)

        let text = try await doctor(tables, json: false).0.stdout
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix("agent ship:") && $0.contains("codex, model gpt-6, effort low") }, "\(text)")
        #expect(lines.contains { $0.hasPrefix("agent plan:") && $0.contains("codex") && $0.contains("effort high") }, "\(text)")
        #expect(text.contains("the PR description on it is bounded by") && text.contains("the plan on it is bounded by"))

        let (_, forbidden) = try await doctor(tables + "allow_unpriced = false\n", json: true)
        let refused = forbidden?["problems"] as? [[String: Any]] ?? []
        #expect(refused.contains { $0["kind"] as? String == "unpriced_not_allowed" && $0["role"] as? String == "plan" })
    }
}
