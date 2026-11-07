import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct AgentSetupTests {
    private static let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"

    private func setup(_ text: String) throws -> AgentSetup { AgentSetup(config: try Config.parse(text + Self.tools)) }

    @Test func theRolesComeInTheOrderAThreadMeetsThem() throws {
        let roles = try setup("").rows.map(\.role)
        #expect(roles == [.goal, .plan, .run, .judge, .review, .ship, .verifier])
    }

    @Test func anEmptyConfigShowsWhatWouldRunAndWhatIsOff() throws {
        let setup = try setup("")
        #expect(setup.row(.run)?.provider == .claude && setup.row(.run)?.source == .providerDefault)
        #expect(setup.row(.review)?.provider == .codex, "review defaults to Codex, as a run resolves it")
        #expect(setup.row(.goal)?.source == .off && setup.row(.goal)?.provider == nil, "no goal agent: a chat is refused")
        #expect(setup.row(.verifier)?.source == .providerDefault, "the verifier is on unless it is turned off")
        #expect(try self.setup("[verifier]\nenabled = false").row(.verifier)?.source == .off)
        #expect(AgentSetup.chatAgent(nil) == nil)
    }

    @Test func aRoleTheConfigSetsIsConfiguredAndAMatchForTheResolverACommandUses() throws {
        let text = """
            [agents.goal]
            provider = "codex"
            model = "gpt-6.1-terra"
            reasoning_effort = "medium"
            [agents.run]
            model = "opus"
            [agents.judge]
            provider = "codex"
            """
        let config = try Config.parse(text + Self.tools)
        let setup = AgentSetup(config: config)
        #expect(setup.row(.goal)?.label == "Codex · gpt-6.1-terra" && setup.row(.goal)?.source == .configured)
        #expect(setup.row(.goal)?.reasoningEffort == "medium")
        #expect(setup.row(.run)?.model == "opus" && setup.row(.run)?.source == .configured)
        // The same resolved values the commands read, not a second reading of the table.
        let run = config.resolvedRunAgent()
        #expect(setup.row(.run)?.provider == run.provider && setup.row(.run)?.model == run.model)
        let judge = config.resolvedJudgeAgent()
        #expect(setup.row(.judge)?.provider == judge.provider && setup.row(.judge)?.model == judge.model)
        #expect(setup.row(.judge)?.label == "Codex · default model")
        #expect(setup.row(.ship)?.source == .providerDefault, "a role with no table is the provider's default")
        #expect(AgentSetup.chatAgent(config) == "Codex · gpt-6.1-terra")
    }

    @Test func theVerifierIsClaudeWithItsOwnModelOrTheDefault() throws {
        let own = try setup("[verifier]\nskill = \"s.md\"\nmodel = \"sonnet\"").row(.verifier)
        #expect(own?.label == "Claude · sonnet" && own?.source == .configured)
        let plain = try setup("[verifier]\nskill = \"s.md\"").row(.verifier)
        #expect(plain?.provider == .claude && plain?.model == nil && plain?.source == .providerDefault)
    }

    @Test func aReviewStageThatChangesProviderDoesNotShowTheOtherProvidersModel() throws {
        let row = try setup("[agents.review]\nprovider = \"codex\"\nmodel = \"gpt-6.1-terra\"").row(.review)
        #expect(row?.provider == .codex && row?.model == "gpt-6.1-terra")
    }

    @Test func aReviewStageThatNamesItsOwnAgentIsConfiguredNotTheProviderDefault() throws {
        let text = "[review]\nstages = [\"pr-review\"]\n[review.stage.pr-review]\nprovider = \"claude\"\nmodel = \"opus\""
        let row = try setup(text).row(.review)
        #expect(row?.provider == .claude && row?.model == "opus" && row?.source == .configured, "\(String(describing: row))")
    }

    @Test func aReviewStageThatDecidesTheRoleLocksItsRow() throws {
        let stage = "[review]\nstages = [\"pr-review\"]\n[review.stage.pr-review]\nprovider = \"claude\"\nmodel = \"opus\""
        #expect(try setup(stage).row(.review)?.lockedBy == "[review.stage.pr-review]")
        #expect(try setup(stage).row(.review)?.lockedFields == [.provider, .model], "only what the stage sets is locked")
        let effortOnly = "[review]\nstages = [\"pr-review\"]\n[review.stage.pr-review]\nreasoning_effort = \"high\""
        #expect(try setup(effortOnly).row(.review)?.lockedFields == [.reasoningEffort], "provider and model still edit")
        #expect(try setup("[agents.review]\nprovider = \"claude\"").row(.review)?.lockedBy == nil)
        #expect(try setup("").rows.allSatisfy { $0.lockedBy == nil })
    }

    @Test func readingWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.toml")
        try ("[agents.goal]\nprovider = \"codex\"\n" + Self.tools).write(to: file, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: file)
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        _ = AgentSetup(config: try Config.load(from: file)).rows
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.toml"])
    }
}
