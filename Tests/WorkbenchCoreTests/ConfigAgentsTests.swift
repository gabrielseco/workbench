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
            model = "gpt-x"
            allow_unpriced = true
            [agents.judge]
            model = "haiku"
            allow_unpriced = true
            [agents.review]
            provider = "codex"
            """)
        #expect(config.agents.goal == AgentSelection(provider: .codex, model: "gpt-x", allowUnpriced: true))
        #expect(config.agents.judge == AgentSelection(provider: nil, model: "haiku", allowUnpriced: true))
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
            model = "m1"
            allow_unpriced = true
            prompt = "docs/D.md"
            [review.stage.pr-review]
            reviewer = "codex"
            """)
        let design = try #require(config.review.stage("design"))
        #expect(design.provider == .codex && design.model == "m1" && design.allowUnpriced == true)
        #expect(config.review.stage("pr-review")?.provider == .codex, "reviewer = \"codex\" is the provider")
        let both = problems("[review.stage.x]\nprompt = \"a.md\"\nreviewer = \"codex\"\nprovider = \"codex\"")
        #expect(both.contains { $0.contains("'reviewer' and 'provider' both choose") })
        let badModel = problems("[review.stage.x]\nprompt = \"a.md\"\nmodel = \"-bad\"")
        #expect(badModel.contains { $0.contains("must be a model name") })
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

    @Test(arguments: [
        ("[agents.run]\nprovider = \"codex\"", "[agents.run] cannot use \"codex\" yet"),
        ("[agents.judge]\nprovider = \"codex\"", "[agents.judge] cannot use \"codex\" yet"),
        ("[agents.review]\nprovider = \"claude\"", "[agents.review] cannot use \"claude\" yet"),
        ("[review.stage.x]\nprompt = \"a.md\"\nprovider = \"claude\"", "[review.stage.x] cannot use \"claude\" yet"),
    ])
    func unsupported(text: String, message: String) {
        let found = problems(text)
        #expect(found.contains { $0.contains(message) && $0.contains("task 4") }, "\(found)")
    }
}
