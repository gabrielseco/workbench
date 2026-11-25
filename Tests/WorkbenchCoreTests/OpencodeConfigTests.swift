import Foundation
import Testing

@testable import WorkbenchCore

private func config(
    _ policy: OpencodeConfig.Policy, base: String = "http://127.0.0.1:4100/v1", model: String = "sonnet-claude",
    variable: String = "LITELLM_API_KEY"
) throws -> OpencodeConfig {
    try OpencodeConfig(policy: policy, providerName: "gateway", modelName: model, baseURL: base, apiKeyVariable: variable)
}

private func parsed(_ config: OpencodeConfig) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: config.json()) as? [String: Any])
}

private func permission(_ config: OpencodeConfig) throws -> [String: Any] {
    try #require(try parsed(config)["permission"] as? [String: Any])
}

@Suite struct OpencodeConfigTests {
    /// Every key below was probed (docs/plan/P28-capabilities.md). An absent rule is allowed, not asked, so each one is explicit.
    private static let toolsAlwaysDenied = [
        "webfetch", "websearch", "external_directory", "task", "skill", "question", "todowrite", "lsp", "doom_loop",
    ]

    @Test func aReadOnlyRunHasNoEditNoShellAndNothingOutsideTheCheckout() throws {
        let rules = try permission(try config(.readOnly))
        #expect(rules["edit"] as? String == "deny")
        let bash = try #require(rules["bash"] as? [String: String])
        #expect(bash == ["*": "deny"], "an allow pattern such as cat* lets a redirect write a file")
        for tool in ["read", "glob", "grep", "list"] { #expect(rules[tool] as? String == "allow", "\(tool)") }
        for tool in Self.toolsAlwaysDenied { #expect(rules[tool] as? String == "deny", "\(tool)") }
    }

    @Test func aCodingRunEditsAndRunsAShellButHasNoNetworkToolAndNothingOutsideTheCheckout() throws {
        let rules = try permission(try config(.coding))
        #expect(rules["edit"] as? String == "allow")
        let bash = try #require(rules["bash"] as? [String: String])
        #expect(bash["*"] == "allow")
        for pattern in ["git push*", "git commit*", "curl*", "wget*"] { #expect(bash[pattern] == "deny", "\(pattern)") }
        for tool in Self.toolsAlwaysDenied { #expect(rules[tool] as? String == "deny", "\(tool)") }
    }

    @Test func noRuleIsLeftToAskOrToItsDefault() throws {
        for policy in [OpencodeConfig.Policy.readOnly, .coding] {
            let rules = try permission(try config(policy))
            func values(_ any: Any) -> [String] {
                if let s = any as? String { return [s] }
                return (any as? [String: Any])?.values.flatMap(values) ?? []
            }
            let all = rules.values.flatMap(values)
            #expect(all.allSatisfy { $0 == "allow" || $0 == "deny" }, "an ask is approved by --auto: \(policy)")
            for key in ["read", "glob", "grep", "list", "edit", "bash"] + Self.toolsAlwaysDenied {
                #expect(rules[key] != nil, "\(key) must be set: \(policy)")
            }
        }
    }

    @Test func theKeyIsNamedNeverWritten() throws {
        let text = try #require(String(data: try config(.coding, variable: "MY_GATEWAY_KEY").json(), encoding: .utf8))
        #expect(text.contains("{env:MY_GATEWAY_KEY}"))
        #expect(!text.contains("sk-") && !text.localizedCaseInsensitiveContains("bearer"))
    }

    @Test func onlyTheOneProviderIsReachableAndItIsAlsoTheTitleModel() throws {
        let object = try parsed(try config(.readOnly))
        #expect(object["enabled_providers"] as? [String] == ["gateway"])
        #expect(object["model"] as? String == "gateway/sonnet-claude")
        #expect(object["small_model"] as? String == "gateway/sonnet-claude")
        let provider = try #require((object["provider"] as? [String: Any])?["gateway"] as? [String: Any])
        let options = try #require(provider["options"] as? [String: Any])
        #expect(options["baseURL"] as? String == "http://127.0.0.1:4100/v1")
        #expect((provider["models"] as? [String: Any])?.keys.sorted() == ["sonnet-claude"])
        #expect(object["share"] as? String == "disabled" && object["autoupdate"] as? Bool == false)
        #expect((object["plugin"] as? [Any])?.isEmpty == true)
    }

    @Test func theSameInputIsTheSameBytes() throws {
        #expect(try config(.coding).json() == config(.coding).json())
        #expect(try config(.coding).json() != config(.readOnly).json())
    }

    @Test(arguments: [
        "ftp://h/v1", "http://", "http://u:p@h/v1", "http://h/v1?key=1", "http://h/v1#x", "http://h /v1", "h/v1", "http://h/v1\n",
    ])
    func aBaseUrlThatIsNotPlainHttpWithAHostIsRefused(url: String) {
        #expect(throws: OpencodeSetupError.self) { try config(.readOnly, base: url) }
    }

    @Test(arguments: ["", "-x", "a/b", "a b", "a#fast", "a\n"])
    func aModelNameThatCouldBeAnotherOptionOrProviderIsRefused(model: String) {
        #expect(throws: OpencodeSetupError.self) { try config(.readOnly, model: model) }
    }

    @Test(arguments: ["", "lower", "1KEY", "A-B", "A B", "A\"B"])
    func aKeyVariableThatIsNotAnEnvironmentNameIsRefused(name: String) {
        #expect(throws: OpencodeSetupError.self) { try config(.readOnly, variable: name) }
    }

    @Test(arguments: ["", "Gateway", "gate way", "a/b", "-a"])
    func aProviderNameThatIsNotASimpleKeyIsRefused(name: String) {
        #expect(throws: OpencodeSetupError.self) {
            try OpencodeConfig(
                policy: .readOnly, providerName: name, modelName: "m", baseURL: "http://127.0.0.1:1/v1", apiKeyVariable: "K")
        }
    }
}

@Suite struct OpencodeRunLayoutTests {
    private let layout = OpencodeRunLayout(root: URL(fileURLWithPath: "/o/turn-1/opencode"))

    @Test func theRunIsPointedAtItsOwnConfigAndNeverTheUsersOrTheCheckouts() {
        let env = layout.environment
        #expect(env["OPENCODE_CONFIG"] == "/o/turn-1/opencode/opencode.json")
        #expect(env["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
        for name in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"] {
            #expect(env[name]?.hasPrefix("/o/turn-1/opencode/state/") == true, "\(name)")
        }
        #expect(Set(env.keys).isSuperset(of: ["TMPDIR"]) && env["TMPDIR"] == "/o/turn-1/opencode/scratch")
        #expect(env["HOME"] == nil, "HOME, PATH and the key come from the provider's allow-list, not from the layout")
    }

    @Test func theConfigAndTheProfileAreOutsideEverythingTheRunMayWrite() {
        let writable = [layout.scratch.path, layout.state.path]
        for file in [layout.configFile, layout.profileFile] {
            #expect(!writable.contains { file.path.hasPrefix($0 + "/") }, "\(file.path) must not be writable by the run")
        }
    }

    @Test func createMakesEveryDirectoryTheRunWritesTo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oc-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let made = OpencodeRunLayout(root: root)
        try made.create()
        var isDirectory: ObjCBool = false
        let stateDirectories = ["config", "data", "state", "cache"].map { made.state.appendingPathComponent($0).path }
        for path in [made.scratch.path] + stateDirectories {
            #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue, "\(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: made.configFile.path), "the caller writes the file, after the layout")
    }
}
