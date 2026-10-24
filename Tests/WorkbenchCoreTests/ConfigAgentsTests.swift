import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ConfigAgentsTests {
    private static let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"

    private func parse(_ text: String) throws -> Config { try Config.parse(text + Self.tools) }

    private func problems(_ text: String) -> [String] {
        do {
            _ = try parse(text)
            return []
        } catch let error as ConfigError { return error.problems.map(\.message) } catch { return ["\(error)"] }
    }

    @Test func legacyDefaults() throws {
        let config = try parse("model = \"opus\"\njudge_model = \"sonnet\"")
        #expect(config.agents == AgentsConfig())
        #expect(config.resolvedRunAgent() == ResolvedAgent(provider: .claude, model: "opus", allowUnpriced: false))
        #expect(config.resolvedJudgeAgent() == ResolvedAgent(provider: .claude, model: "sonnet", allowUnpriced: false))
        #expect(config.resolvedReviewAgent() == ResolvedAgent(provider: .codex, model: nil, allowUnpriced: false))
        #expect(config.resolvedGoalAgent == nil)
        let bare = try parse("")
        #expect(bare.resolvedJudgeAgent().model == nil && bare.resolvedRunAgent().model == nil)
        #expect(try parse("model = \"opus\"").resolvedJudgeAgent().model == "opus", "the judge still falls back to model")
    }

    @Test func providers() throws {
        let config = try parse(
            "[providers.codex]\nexecutable = \"/opt/codex\"\n[providers.claude]\nexecutable = \"/opt/claude\"")
        #expect(config.executable(for: .codex) == "/opt/codex")
        #expect(config.claudePath == "/opt/claude" && config.executable(for: .claude) == "/opt/claude")
        #expect(try parse("").executable(for: .codex) == "codex")
        #expect(try parse("claude_path = \"/x/claude\"").executable(for: .claude) == "/x/claude")
        #expect(problems("[providers.gemini]\nexecutable = \"g\"").contains { $0.contains("unknown table [providers.gemini]") })
        #expect(problems("[providers.codex]\nbogus = 1").contains("unknown key 'bogus' in [providers.codex]"))
        let empty = problems("[providers.codex]\nexecutable = \"\"")
        #expect(empty.contains { $0.contains("command name or a path") })
        let newline = problems("[providers.codex]\nexecutable = \"a\\nb\"")
        #expect(newline.contains { $0.contains("command name or a path") }, "\(newline)")
        #expect(problems("[providers.codex]\nexecutable = 3").contains { $0.contains("must be a string") })
        #expect(problems("[providers]\nexecutable = \"x\"").contains("unknown table [providers]"))
        let both = problems("claude_path = \"a\"\n[providers.claude]\nexecutable = \"b\"")
        #expect(both.contains { $0.contains("'claude_path' and [providers.claude]") })
    }

    @Test func agents() throws {
        let config = try parse(
            """
            [agents.goal]
            provider = "codex"
            allow_unpriced = true
            [agents.judge]
            model = "haiku"
            allow_unpriced = true
            [agents.review]
            provider = "codex"
            """)
        #expect(config.agents.goal == AgentSelection(provider: .codex, allowUnpriced: true))
        #expect(problems("[agents.goal]\nprovider = \"codex\"\nmodel = \"gpt-x\"\nreasoning_effort = \"high\"").isEmpty)
        #expect(config.agents.judge == AgentSelection(provider: nil, model: "haiku", allowUnpriced: true))
        #expect(
            problems("[agents.judge]\nreasoning_effort = \"ultra\"")
                .contains { $0.contains("'reasoning_effort'") && $0.contains("\"xhigh\"") })
        #expect(problems("[agents.judge]\nreasoning_effort = 3").contains { $0.contains("'reasoning_effort' must be a string") })
        #expect(problems("[agents.run]\nreasoning_effort = \"low\"").contains { $0.contains("not allowed in [agents.run]") })
        #expect(problems("[agents.plan]\nmodel = \"x\"").contains { $0.contains("unknown table [agents.plan]") })
        #expect(problems("[agents.judge]\nbogus = 1").contains("unknown key 'bogus' in [agents.judge]"))
        #expect(problems("[agents.judge]\nprovider = \"gemini\"").contains { $0.contains("must be \"claude\" or \"codex\"") })
        #expect(problems("[agents.judge]\nmodel = \"-x\"").contains { $0.contains("must be a model name") })
        #expect(problems("[agents.judge]\nmodel = 4").contains { $0.contains("'model' must be a string") })
        #expect(problems("[agents.judge]\nallow_unpriced = \"yes\"").contains { $0.contains("true or false") })
        #expect(problems("[agents.run]\nallow_unpriced = true").contains { $0.contains("approved in the goal") })
        #expect(problems("[agents.goal]\nmodel = \"x\"").contains { $0.contains("missing key 'provider' in [agents.goal]") })
        #expect(problems("[agents]\nmodel = \"x\"").contains("unknown table [agents]"))
    }

    @Test func reviewStage() throws {
        let config = try parse(
            """
            [review]
            stages = ["pr-review", "design"]
            [review.stage.design]
            provider = "codex"
            allow_unpriced = true
            prompt = "docs/D.md"
            [review.stage.pr-review]
            reviewer = "codex"
            """)
        let design = try #require(config.review.stage("design"))
        #expect(design.provider == .codex && design.model == nil && design.allowUnpriced == true)
        #expect(config.review.stage("pr-review")?.provider == .codex, "reviewer = \"codex\" is the provider")
        let both = problems("[review.stage.x]\nprompt = \"a.md\"\nreviewer = \"codex\"\nprovider = \"codex\"")
        #expect(both.contains { $0.contains("'reviewer' and 'provider' both choose") })
        // A Codex judge or review takes a model and an effort, from its own table, the default, or the stage that inherits it.
        let table = "[review.stage.x]\nprompt = \"a.md\"\nprovider = \"codex\"\nmodel = \"m1\"\nreasoning_effort = \"high\""
        #expect(problems(table).isEmpty)
        #expect(problems("[agents.review]\nmodel = \"m1\"").isEmpty)
        #expect(problems("[agents.judge]\nprovider = \"codex\"\nmodel = \"m1\"").isEmpty)
        let inherited = try parse(
            "[agents.review]\nmodel = \"m1\"\nreasoning_effort = \"high\"\n[review]\nstages = [\"pr-review\", \"x\"]\n"
                + "[review.stage.x]\nprompt = \"a.md\"\nprovider = \"claude\"")
        #expect(
            inherited.resolvedReviewAgent()
                == ResolvedAgent(provider: .codex, model: "m1", reasoningEffort: "high", allowUnpriced: false))
        #expect(inherited.resolvedReviewAgent(stage: "x").model == nil, "a model names one provider's model")
        #expect(
            problems(
                "[agents.review]\nprovider = \"claude\"\n[review]\nstages = [\"pr-review\", \"x\"]\n"
                    + "[review.stage.x]\nprovider = \"claude\"\nmodel = \"haiku\"\nprompt = \"a.md\"")
                .isEmpty)
        #expect(try parse("[pr_review]\nmax_rounds = 2").review.prReview.provider == nil)
    }

    @Test func resolution() throws {
        var config = try parse("model = \"opus\"\njudge_model = \"sonnet\"")
        // The judge: a flag, then [agents.judge], then the legacy keys only while [agents.judge] chooses nothing.
        #expect(config.resolvedJudgeAgent(modelFlag: "haiku").model == "haiku")
        config.agents.judge = AgentSelection(model: "fast")
        #expect(config.resolvedJudgeAgent().model == "fast")
        config.agents.judge = AgentSelection(provider: .claude)
        #expect(config.resolvedJudgeAgent().model == nil, "choosing a provider replaces the legacy models")
        config.agents.judge = AgentSelection(allowUnpriced: true)
        #expect(config.resolvedJudgeAgent().model == "sonnet" && config.resolvedJudgeAgent().allowUnpriced)
        // A legacy alias never goes to another provider.
        config.agents.judge = AgentSelection(provider: .codex)
        #expect(config.resolvedJudgeAgent().model == nil)
        config.agents.run = AgentSelection(provider: .codex)
        #expect(config.resolvedRunAgent().model == nil && config.resolvedRunAgent(goalModel: "g").model == "g")
        config.agents.run = AgentSelection(model: "run-model")
        #expect(config.resolvedRunAgent().model == "run-model" && config.resolvedRunAgent(goalModel: "g").model == "g")
        // Drafting never inherits the coding model.
        config.agents.goal = AgentSelection(provider: .claude)
        #expect(config.resolvedGoalAgent == ResolvedAgent(provider: .claude, model: nil, allowUnpriced: false))
        // Review: stage, then [agents.review]; allow_unpriced is inherited unless the stage sets it.
        var review = ReviewConfig()
        var design = ReviewStageConfig(name: "design")
        design.model = "stage-model"
        review.definitions["design"] = design
        var quiet = ReviewStageConfig(name: "quiet")
        quiet.allowUnpriced = false
        review.definitions["quiet"] = quiet
        config.review = review
        config.agents.review = AgentSelection(model: "review-model", allowUnpriced: true)
        let designAgent = config.resolvedReviewAgent(stage: "design")
        #expect(designAgent == ResolvedAgent(provider: .codex, model: "stage-model", allowUnpriced: true))
        #expect(config.resolvedReviewAgent(stage: "quiet").allowUnpriced == false)
        #expect(config.resolvedReviewAgent().model == "review-model")
        #expect(config.resolvedReviewAgent(stage: "unknown").model == "review-model")
    }

    @Test func agentsReviewJudgeProviders() throws {
        let both = try parse(
            "[agents.judge]\nprovider = \"codex\"\nallow_unpriced = true\n"
                + "[agents.review]\nprovider = \"claude\"\nmodel = \"haiku\"")
        #expect(both.resolvedJudgeAgent() == ResolvedAgent(provider: .codex, model: nil, allowUnpriced: true))
        #expect(both.resolvedReviewAgent() == ResolvedAgent(provider: .claude, model: "haiku", allowUnpriced: false))
        let stage = try parse(
            """
            [agents.review]
            provider = "claude"
            model = "haiku"
            [review]
            stages = ["pr-review", "design"]
            [review.stage.design]
            prompt = "d.md"
            provider = "codex"
            allow_unpriced = true
            """)
        // A model belongs to its provider: the stage that moves to Codex does not inherit Claude's.
        #expect(stage.resolvedReviewAgent(stage: "design") == ResolvedAgent(provider: .codex, model: nil, allowUnpriced: true))
        #expect(stage.resolvedReviewAgent().model == "haiku")
        #expect(problems("[agents.judge]\nprovider = \"gemini\"").contains { $0.contains("must be \"claude\" or \"codex\"") })
    }

    @Test func aModelInheritingCodexIsAccepted() throws {
        let text = "[review]\nstages = [\"pr-review\", \"x\"]\n[review.stage.x]\nprompt = \"a.md\"\nmodel = \"haiku\"\n"
        #expect(try parse(text).resolvedReviewAgent(stage: "x").model == "haiku")
    }

    @Test func runOnCodexIsAccepted() throws {
        let config = try parse("[agents.run]\nprovider = \"codex\"")
        #expect(config.resolvedRunAgent().provider == .codex)
        #expect(config.resolvedRunAgent().model == nil)
        // The legacy root `model` is a Claude alias and never reaches Codex.
        #expect(try parse("model = \"opus\"\n[agents.run]\nprovider = \"codex\"").resolvedRunAgent().model == nil)
    }

    @Test func runModelOnCodexIsRefused() {
        let found = problems("[agents.run]\nprovider = \"codex\"\nmodel = \"gpt-x\"")
        #expect(found.contains { $0.contains("takes no model") }, "\(found)")
        #expect(problems("[agents.run]\nprovider = \"claude\"\nmodel = \"opus\"").isEmpty)
    }

    @Test func legacyReviewSelection() throws {
        #expect(try parse("").reviewUsesLegacySelection())
        #expect(try parse("[pr_review]\nmax_rounds = 2").reviewUsesLegacySelection())
        #expect(try parse("[agents.review]\nallow_unpriced = true").reviewUsesLegacySelection(), "no provider chosen")
        #expect(try parse("[review.stage.pr-review]\nreviewer = \"codex\"").reviewUsesLegacySelection(), "P6's key is not new")
        #expect(!(try parse("[agents.review]\nprovider = \"codex\"").reviewUsesLegacySelection()))
        #expect(!(try parse("[review.stage.pr-review]\nprovider = \"codex\"").reviewUsesLegacySelection()))
        let named = try parse(
            "[agents.review]\nprovider = \"claude\"\n[review]\nstages = [\"pr-review\", \"x\"]\n"
                + "[review.stage.x]\nprompt = \"a.md\"\nprovider = \"codex\"")
        #expect(named.allowUnpricedTable(.review, stage: "x") == "[agents.review] or [review.stage.x]")
        #expect(named.allowUnpricedTable(.judge) == "[agents.judge]")
    }
}
