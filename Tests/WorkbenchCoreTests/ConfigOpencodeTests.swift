import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ConfigOpencodeTests {
    private static let tools = "\n[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"
    private static let gateway = "[providers.opencode]\nbase_url = \"https://gw.example/v1\"\n"

    private func parse(_ text: String) throws -> Config { try Config.parse(text + Self.tools) }

    private func problems(_ text: String) -> [String] {
        do {
            _ = try parse(text)
            return []
        } catch let error as ConfigError { return error.problems.map(\.message) } catch { return ["\(error)"] }
    }

    @Test func theGatewayIsReadFromItsTableAndTheKeyVariableDefaults() throws {
        let config = try parse(Self.gateway)
        #expect(config.agents.opencode == OpencodeProvider.Gateway(baseURL: "https://gw.example/v1"))
        #expect(config.agents.opencode?.apiKeyVariable == "LITELLM_API_KEY")
        let extras = "api_key_env = \"MY_KEY\"\nexecutable = \"/o/opencode\"\nmodels = [\"sonnet-claude\"]"
        let named = try parse(Self.gateway + extras)
        #expect(named.agents.opencode?.apiKeyVariable == "MY_KEY")
        #expect(named.executable(for: .opencode) == "/o/opencode" && config.executable(for: .opencode) == "opencode")
        #expect(named.agents.models[.opencode] == ["sonnet-claude"])
        #expect(try parse("").agents.opencode == nil)
    }

    @Test func planAndShipCanRunOnOpencodeWithItsModelNameAndNothingElseChanges() throws {
        let config = try parse(
            Self.gateway + "[agents.plan]\nprovider = \"opencode\"\nmodel = \"opus-claude\"\n"
                + "[agents.ship]\nprovider = \"opencode\"\nmodel = \"haiku-claude\"\nallow_unpriced = true")
        #expect(config.resolvedPlanAgent().provider == .opencode && config.resolvedPlanAgent().model == "opus-claude")
        #expect(config.resolvedShipAgent.provider == .opencode && config.resolvedShipAgent.allowUnpriced)
        #expect(config.resolvedRunAgent().provider == .claude && config.resolvedJudgeAgent().provider == .claude)
        #expect(config.resolvedReviewAgent().provider == .codex, "the defaults of every other role are unchanged")
    }

    @Test func anAgentTableMayComeBeforeTheGatewayItNeeds() throws {
        let config = try parse("[agents.plan]\nprovider = \"opencode\"\nmodel = \"m\"\n\n" + Self.gateway)
        #expect(config.resolvedPlanAgent().provider == .opencode)
    }

    @Test func aRoleNamingOpencodeWithNoGatewayIsRefusedAtLoadWithWhatToAdd() {
        let found = problems("[agents.plan]\nprovider = \"opencode\"")
        #expect(found.count == 1 && found[0].contains("[providers.opencode]") && found[0].contains("base_url"), "\(found)")
    }

    @Test func theCodingAndJudgeRolesCanRunOnOpencodeWithTheGatewayAndNoEffort() throws {
        let config = try parse(
            Self.gateway + "[agents.run]\nprovider = \"opencode\"\nmodel = \"sonnet-claude\"\n"
                + "[agents.judge]\nprovider = \"opencode\"\nmodel = \"opus-claude\"")
        #expect(config.resolvedRunAgent().provider == .opencode && config.resolvedRunAgent().model == "sonnet-claude")
        #expect(config.resolvedJudgeAgent().provider == .opencode && config.resolvedJudgeAgent().model == "opus-claude")
        #expect(config.resolvedReviewAgent().provider == .codex, "no other role moves")
        let found = problems(Self.gateway + "[agents.run]\nprovider = \"opencode\"\nreasoning_effort = \"high\"")
        #expect(found.count == 1 && found[0].contains("reasoning_effort") && found[0].contains("opencode"), "\(found)")
        let noGateway = problems("[agents.run]\nprovider = \"opencode\"")
        #expect(noGateway.count == 1 && noGateway[0].contains("[providers.opencode]"), "\(noGateway)")
    }

    @Test(arguments: ["review", "goal"])
    func aRoleNotYetProvenOnOpencodeIsRefusedAtLoadNotAtRunTime(role: String) {
        let found = problems(Self.gateway + "[agents.\(role)]\nprovider = \"opencode\"")
        #expect(found.count == 1 && found[0].contains("cannot use \"opencode\" yet"), "\(role): \(found)")
        #expect(found[0].contains("\"claude\" or \"codex\""), "it says what the role does run on")
    }

    @Test(arguments: [
        "base_url = \"ftp://gw/v1\"", "base_url = \"http://u:p@gw/v1\"", "base_url = \"gw/v1\"", "base_url = \"https://gw/v1?k=1\"",
        "base_url = 5", "base_url = \"https://gw/v1\"\napi_key_env = \"lower\"", "base_url = \"https://gw/v1\"\napi_key_env = 3",
    ])
    func aBadGatewayValueIsAProblemNamingTheKey(lines: String) {
        let found = problems("[providers.opencode]\n\(lines)\n")
        #expect(!found.isEmpty, "\(lines)")
        let names = ["base_url", "api_key_env"]
        #expect(found.allSatisfy { message in names.contains { message.contains($0) } }, "\(found)")
    }

    @Test func theTableWithNoBaseUrlSaysSo() {
        let found = problems("[providers.opencode]\nexecutable = \"/o/opencode\"")
        #expect(found.count == 1 && found[0].contains("needs 'base_url'"), "\(found)")
    }

    @Test func theGatewayKeysBelongToOpencodeOnly() {
        let found = problems("[providers.codex]\nbase_url = \"https://gw/v1\"")
        #expect(found.count == 1 && found[0].contains("unknown key 'base_url'"), "\(found)")
        #expect(found.first?.contains("[providers.opencode]") == true, "it says where the key belongs")
    }

    @Test func theKeyItselfIsNotAKeyOfTheTable() {
        let found = problems(Self.gateway + "api_key = \"secret\"")
        #expect(found.count == 1 && found[0].contains("unknown key 'api_key'"), "the config names a variable, never a key")
    }

    @Test func theRegistriesBuildTheAdapterOnlyForAConfiguredGateway() throws {
        let configured = try parse(Self.gateway)
        let provider = try #require(configured.agentProvider(.opencode))
        #expect(provider.id == .opencode && provider.capabilities.policies.contains(.readOnlyEvidence))
        #expect(configured.readOnlyAgent(.opencode, environment: [:]) is OpencodeReadOnlyAgent)
        let bare = try parse("")
        #expect(bare.agentProvider(.opencode) == nil && bare.readOnlyAgent(.opencode, environment: [:]) == nil)
    }

    @Test func aPlanOrShipTurnOnOpencodeIsRefusedWhenTheConfigForbidsUnpricedAndPassesOtherwise() throws {
        let config = try parse(
            Self.gateway + "[agents.plan]\nprovider = \"opencode\"\nmodel = \"m\"\nallow_unpriced = false")
        let agent = config.resolvedPlanAgent()
        let refused = ThreadService.readOnlyAgent(role: .plan, agent: agent, config: config, cap: 1, environment: [:])
        guard case .failure(let failure) = refused else { Issue.record("expected a refusal"); return }
        #expect(failure.kind == .unsupportedCapability && failure.message.contains("dollar"), "\(failure.message)")
        let open = try parse(Self.gateway + "[agents.plan]\nprovider = \"opencode\"\nmodel = \"m\"\nallow_unpriced = true")
        guard case .success = ThreadService.readOnlyAgent(
            role: .plan, agent: open.resolvedPlanAgent(), config: open, cap: 1, environment: [:])
        else { Issue.record("expected an agent"); return }
    }
}
