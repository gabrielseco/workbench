import Foundation
import Testing

@testable import WorkbenchCore

private let gateway = "[providers.opencode]\nbase_url = \"https://gw.example/v1\"\n"
private let models = "models = [\"gemini-4-neon\", \"sonnet-claude\"]\n"

/// A project folder with a config file of its own, for edits.
private func project(_ text: String) throws -> Project {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-oc-\(UUID().uuidString)")
    let project = Project(root: root)
    try FileManager.default.createDirectory(at: project.workbenchDirectory, withIntermediateDirectories: true)
    try text.write(to: project.configURL, atomically: true, encoding: .utf8)
    return project
}

private func tools() -> String { Config.exampleTOML }

private func text(_ project: Project) throws -> String { try String(contentsOf: project.configURL, encoding: .utf8) }

private func set(_ role: AgentRole, _ provider: String, in project: Project) throws {
    _ = try ConfigEdit.set(ConfigEdit.Key(role: role, field: .provider), to: provider, in: project)
}

@Suite struct AgentOpencodeSetupTests {
    private func setup(_ extra: String) throws -> AgentSetup { AgentSetup(config: try Config.parse(tools() + extra)) }

    @Test func openCodeIsOfferedOnlyWhereTheProjectNamesItsGatewayAndNeverForTheVerifier() throws {
        let without = try setup("")
        #expect(without.rows.allSatisfy { $0.providerOptions == [.claude, .codex] })
        let with = try setup("\n" + gateway)
        for row in with.rows {
            let offered = row.providerOptions.contains(.opencode)
            #expect(offered == (row.role != .verifier), "\(row.role)")
        }
        #expect(AgentSetup.name(.opencode) == "OpenCode")
    }

    @Test func draftingOffersOpenCodeOnlyWhenPickingItWouldAlsoSetAModel() throws {
        func choices(_ extra: String) throws -> [AgentProviderID] {
            AgentSetup.draftChoices(config: try Config.parse(tools() + extra))
        }
        #expect(try choices("") == [.claude, .codex])
        #expect(try choices("\n" + gateway) == [.claude, .codex], "no model to set: the draft would be refused")
        #expect(try choices("\n" + gateway + "models = []\n") == [.claude, .codex])
        #expect(try choices("\n" + gateway + models) == [.claude, .codex, .opencode])
    }

    @Test func itsMenuIsTheProjectsModelsAndTheOnesItsRolesUse() throws {
        let rows = try setup("\n" + gateway + models + "[agents.run]\nprovider = \"opencode\"\nmodel = \"other-model\"\n")
        #expect(rows.row(.run)?.modelOptions == ["gemini-4-neon", "sonnet-claude", "other-model"])
        #expect(rows.row(.run)?.label == "OpenCode · other-model")
    }

    @Test func onlyClaudeCodesOwnAliasesAreFlaggedAsNotAGatewayModel() {
        for name in ["opus", "sonnet", "haiku"] { #expect(AgentSetup.modelFit(provider: .opencode, model: name) == .claude) }
        for name in ["claude-sonnet-5-5", "sonnet-claude", "gpt-6-sol", "gemini-4-neon"] {
            #expect(AgentSetup.modelFit(provider: .opencode, model: name) == nil, "\(name)")
        }
    }

    @Test func switchingToOpenCodeReplacesTheModelAndDropsTheEffortInOneValidWrite() throws {
        let p = try project(
            tools() + "\n" + gateway + models
                + "\n[agents.run] # coding\nprovider = \"claude\"\nmodel = \"opus\"\nreasoning_effort = \"high\"\n")
        defer { try? FileManager.default.removeItem(at: p.root) }
        try set(.run, "opencode", in: p)
        let config = try Config.load(from: p.configURL)
        #expect(config.resolvedRunAgent().provider == .opencode && config.resolvedRunAgent().model == "gemini-4-neon")
        #expect(config.resolvedRunAgent().reasoningEffort == nil)
        #expect(try text(p).contains("[agents.run] # coding"), "the rest of the file is left as it is")
    }

    @Test func switchingAwayDropsTheGatewaysModelName() throws {
        let judge = "\n[agents.judge]\nprovider = \"opencode\"\nmodel = \"gemini-4-neon\"\n"
        let p = try project(tools() + "\n" + gateway + models + judge)
        defer { try? FileManager.default.removeItem(at: p.root) }
        try set(.judge, "claude", in: p)
        let config = try Config.load(from: p.configURL)
        #expect(config.resolvedJudgeAgent().provider == .claude && config.resolvedJudgeAgent().model == nil)
    }

    @Test func withNoModelsListedTheModelIsLeftUnsetNotCarriedOver() throws {
        let p = try project(tools() + "\n" + gateway + "\n[agents.plan]\nprovider = \"claude\"\nmodel = \"opus\"\n")
        defer { try? FileManager.default.removeItem(at: p.root) }
        try set(.plan, "opencode", in: p)
        #expect(try Config.load(from: p.configURL).resolvedPlanAgent().model == nil)
    }

    @Test func aRoleWithNoTableAndTheGoalAgentCanBeNamedToo() throws {
        let p = try project(tools() + "\n" + gateway + models)
        defer { try? FileManager.default.removeItem(at: p.root) }
        try set(.goal, "opencode", in: p)
        let goal = try #require(try Config.load(from: p.configURL).resolvedGoalAgent)
        #expect(goal.provider == .opencode && goal.model == "gemini-4-neon")
    }

    @Test func betweenClaudeAndCodexNothingElseChanges() throws {
        let p = try project(tools() + "\n[agents.run]\nprovider = \"claude\"\nmodel = \"opus\"\nreasoning_effort = \"high\"\n")
        defer { try? FileManager.default.removeItem(at: p.root) }
        try set(.run, "codex", in: p)
        let run = try Config.load(from: p.configURL).resolvedRunAgent()
        #expect(run.model == "opus" && run.reasoningEffort == "high")
    }

    @Test func aProjectWithNoGatewayRefusesAndIsLeftAsItWas() throws {
        let original = tools() + "\n[agents.run]\nprovider = \"claude\"\nmodel = \"opus\"\n"
        let p = try project(original)
        defer { try? FileManager.default.removeItem(at: p.root) }
        #expect(throws: ConfigEdit.Failure.self) { try set(.run, "opencode", in: p) }
        #expect(try text(p) == original)
    }
}
