import Foundation
import Testing

@testable import WorkbenchCore

/// The automated review on either provider (P9 PR 13): Claude through its read-only adapter, Codex as before, and the
/// spending rule for the one without a dollar cap.
@Suite(.processGate) struct ReviewProvidersTests {
    private func claudeReview(
        _ answer: String = "Fine.\nVERDICT: CLEAN\n", extraConfig: String = ""
    ) async throws -> (r: ReviewedPR, env: [String: String]) {
        var r = try await reviewedPR(extraConfig: extraConfig)
        r.config.agents.review = AgentSelection(provider: .claude)
        let file = r.codex.dir.appendingPathComponent("claude-answer.txt")
        try answer.write(to: file, atomically: true, encoding: .utf8)
        return (r, r.codex.environment(["FAKE_CLAUDE": "answer=\(file.path)"]))
    }

    private func argv(_ event: Event?) -> [String] {
        if case .array(let items)? = event?.data["argv"] { return items.compactMap(\.stringValue) }
        return []
    }

    private func attempts(_ r: ReviewedPR) throws -> [Event] {
        try r.fx.events(r.id).filter { $0.kind == .agentAttemptStarted || $0.kind == .agentAttemptEnded }
            .filter { $0.data["role"] == "review" || $0.data["role"] == nil }
    }

    @Test func claudeReviewRound() async throws {
        let (r, env) = try await claudeReview()
        let result = try await r.round(environment: env)
        #expect(result.verdict == .clean && result.failure == nil)
        #expect(r.codex.runs == 0, "Codex was not started")
        let started = try #require(r.started.first), finished = try #require(r.finished.first)
        #expect(started.data["provider"] == "claude" && finished.data["provider"] == "claude")
        let argv = argv(started)
        #expect(argv.contains("--restricted") && argv.contains("--max-budget-usd") && argv.contains("--session-id"), "\(argv)")
        #expect(argv.contains("Read") && !argv.contains("Bash"), "\(argv)")
        // The same findings file as for Codex, in the round's folder.
        let findings = try String(contentsOf: r.folder.appendingPathComponent("round-1.findings.md"), encoding: .utf8)
        #expect(findings.contains("VERDICT: CLEAN"))
        #expect(finished.data["findings_path"] == "pr-review/round-1.findings.md")
        try await r.expectNoLeftovers()
    }

    @Test func theSessionOnRecordIsTheSessionThatRan() async throws {
        let (r, base) = try await claudeReview()
        let dump = r.codex.dir.appendingPathComponent("dump.json")
        let env = base.merging(["FAKE_CLAUDE": base["FAKE_CLAUDE"]! + ",dump=\(dump.path)"]) { $1 }
        _ = try await r.round(environment: env)
        let logged = argv(r.started.first)
        let id = try #require(logged.firstIndex(of: "--session-id").map { logged[$0 + 1] })
        let ran = try String(contentsOf: dump, encoding: .utf8).lowercased()
        #expect(ran.contains(id), "the id in the log, \(id), is the one claude was started with")
    }

    @Test func claudeReviewSameValidators() async throws {
        let fix = try await claudeReview("- a.txt: wrong.\nVERDICT: FIX\n")
        #expect(try await fix.r.round(environment: fix.env).verdict == .fix)
        for bad in ["All fine.\n", "VERDICT: CLEAN\nVERDICT: FIX\n", "VERDICT: CLEAN\ntrailing words\n"] {
            let (r, env) = try await claudeReview(bad)
            let result = try await r.round(environment: env)
            #expect(result.verdict == nil && result.failure?.contains("VERDICT: CLEAN") == true, "\(bad): \(result)")
            #expect(r.finished.first?.data["ok"] == false)
        }
        // Over the answer cap: not accepted, as for Codex.
        let big = String(repeating: "0123456789", count: 30_000) + "\nVERDICT: CLEAN\n"
        let (r, env) = try await claudeReview(big)
        let result = try await r.round(environment: env)
        #expect(result.verdict == nil && result.failure?.contains("larger than") == true, "\(result)")
    }

    @Test func claudeReviewCountsRounds() async throws {
        let (r, env) = try await claudeReview(extraConfig: "[pr_review]\nmax_rounds = 2")
        _ = try await r.round(environment: env)
        _ = try await r.round(again: true, environment: env)
        #expect(r.started.count == 2 && r.finished.count == 2)
        await #expect(throws: PRReviewRefusal.capReached(pr: 12, rounds: 2, max: 2)) {
            _ = try await r.round(again: true, environment: env)
        }
        #expect(r.started.count == 2, "a refused round writes nothing")
    }

    @Test func claudeReviewKeepsCap() async throws {
        let (r, env) = try await claudeReview()
        // allow_unpriced changes nothing for a provider that has a cap.
        var config = r.config
        config.agents.review = AgentSelection(provider: .claude, allowUnpriced: true)
        let result = try await r.fx.service.prReview(
            id: r.id, config: config, codexPath: r.codex.path, environment: env, timeout: 30, capacityBackoff: { _ in 0 })
        #expect(result.verdict == .clean)
        let argv = argv(r.started.first)
        let cap = argv.firstIndex(of: "--max-budget-usd").map { argv[$0 + 1] }
        #expect(cap == "2", "\(argv)")
    }

    @Test func claudeReviewCostRecorded() async throws {
        let (r, env) = try await claudeReview()
        let result = try await r.round(environment: env)
        #expect(result.costUSD == 0.001)
        #expect(r.finished.first?.data["cost_usd"] == .double(0.001))
        #expect(try ThreadState.derive(from: r.fx.events(r.id), id: r.id).review.prReview?.costUSD == 0.001)
        // Codex reports none: the field is absent, never 0.
        let codex = try await reviewedPR()
        _ = try await codex.round()
        #expect(codex.finished.first?.data["cost_usd"] == nil)
        #expect(try ThreadState.derive(from: codex.fx.events(codex.id), id: codex.id).review.prReview?.costUSD == nil)
    }

    @Test func claudeReviewRefusesProof() async throws {
        let (r, env) = try await claudeReview(extraConfig: "[review.stage.pr-review]\ninputs = [\"diff\", \"goal\", \"proof\"]")
        try await recordVerifierProof(r.fx, r.id, ["home.png": "pixels"])
        let result = try await r.round(environment: env)
        #expect(result.verdict == nil)
        #expect(result.failure?.contains("cannot take images") == true, "\(String(describing: result.failure))")
        #expect(r.finished.first?.data["ok"] == false)
        // Also with no proof to attach: the reason is the provider's, not a missing screenshot.
        let (bare, bareEnv) = try await claudeReview(extraConfig: "[review.stage.pr-review]\ninputs = [\"diff\", \"proof\"]")
        let noProof = try await bare.round(environment: bareEnv)
        #expect(noProof.failure?.contains("cannot take images") == true, "\(String(describing: noProof.failure))")
        let pair = try attempts(r).filter { $0.data["role"] == "review" || $0.kind == .agentAttemptEnded }
        #expect(pair.last?.data["outcome"] == "refused", "nothing was started: \(pair.map(\.data))")
        try await r.expectNoLeftovers()
    }

    @Test func capacityRetryIsProviderNeutral() async throws {
        // Codex is the provider with a capacity answer today; the loop is the same for any provider.
        let r = try await reviewedPR()
        try r.codex.put("capacity_until", "2")
        let result = try await r.round()
        #expect(result.verdict == .clean && result.round == 1)
        #expect(r.started.count == 1 && r.codex.runs == 3)
        #expect(try attempts(r).filter { $0.kind == .agentAttemptStarted }.count == 3)
        // Exhausted: a failed round, never a pass.
        let tired = try await reviewedPR()
        try tired.codex.put("capacity_until", "9")
        let failed = try await tired.round()
        let why = String(describing: failed.failure)
        #expect(failed.verdict == nil && why.contains("at capacity 3 times"), "\(why)")
        #expect(tired.codex.runs == 3)
    }

    @Test func codexReviewNeedsAllowUnpriced() async throws {
        var r = try await reviewedPR()
        r.config.agents.review = AgentSelection(provider: .codex)
        let result = try await r.round()
        #expect(result.verdict == nil && r.codex.runs == 0, "refused before spawn")
        let why = try #require(result.failure)
        #expect(why.contains("allow_unpriced") && why.contains("[agents.review]"), "\(why)")
        #expect(r.finished.first?.data["ok"] == false && r.started.count == 1)
        let pair = try attempts(r)
        #expect(pair.last?.data["outcome"] == "refused")
        // With the opt-in it runs, timeout-only.
        r.config.agents.review = AgentSelection(provider: .codex, allowUnpriced: true)
        let allowed = try await r.round(again: true)
        #expect(allowed.verdict == .clean && r.codex.runs == 1)
    }

    @Test func stageInheritsAllowUnpriced() async throws {
        let stages =
            "[review]\nstages = [\"pr-review\", \"design\"]\n[review.stage.design]\nprompt = \"docs/D.md\"\n"
            + "provider = \"codex\"\n"
        var r = try await reviewedPR(extraConfig: stages)
        r.config.agents.review = AgentSelection(provider: .claude, allowUnpriced: true)
        let agent = r.config.resolvedReviewAgent(stage: "design")
        #expect(agent.provider == .codex && agent.allowUnpriced, "the stage inherits the opt-in")
        let table = r.config.allowUnpricedTable(.review, stage: "design")
        #expect(table == "[agents.review] or [review.stage.design]")
        r.config.agents.review = AgentSelection(provider: .claude)
        #expect(!r.config.resolvedReviewAgent(stage: "design").allowUnpriced)
        let refusal = AgentSpendPolicy.spend(
            role: .review, agent: r.config.resolvedReviewAgent(stage: "design"), capabilities: CodexProvider().capabilities,
            cap: 2, legacy: false, table: table)
        guard case .failure(let failure) = refusal else {
            Issue.record("a Codex stage without the opt-in must be refused")
            return
        }
        #expect(failure.message.contains("allow_unpriced") && failure.message.contains("[review.stage.design]"))
    }

    @Test func legacyCodexReviewNeedsNoOptIn() async throws {
        let r = try await reviewedPR()
        #expect(r.config.reviewUsesLegacySelection())
        let result = try await r.round()
        #expect(result.verdict == .clean && r.codex.runs == 1)
        #expect(!(r.codex.read("calls") ?? "").contains("--max-budget-usd"))
    }
}
