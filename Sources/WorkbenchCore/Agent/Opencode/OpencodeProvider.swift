import Foundation

/// The OpenCode adapter. Every role can run on it, through one OpenAI-compatible gateway (a LiteLLM proxy), with the limits in
/// `docs/plan/P28-capabilities.md`:
///
/// - **Read-only** turns get no shell and no edit tool (`OpencodeConfig.Policy.readOnly`); reads are confined to the working directory.
/// - **Coding** turns run the whole `opencode` process under `sandbox-exec` (`OpencodeSandbox`), because OpenCode's own rules cannot
///   confine a shell. That needs macOS and a loopback forwarder that carries the model's traffic and holds the real key; without both
///   the request is refused, never run unconfined.
/// - There is no dollar cap, no resume, no images, no reasoning effort and no extra grants yet: a request that needs one is refused.
///
/// A run never passes `--auto`, never reads the person's own OpenCode config or the checkout's `opencode.json`, and has no environment
/// but the minimal set and the gateway key.
public struct OpencodeProvider: AgentProvider {
    /// Where the model is. `providerName/model` is what `-m` gets; the key is read from `apiKeyVariable` and written nowhere.
    public struct Gateway: Sendable, Equatable {
        public var providerName: String
        public var baseURL: String
        public var apiKeyVariable: String

        public init(providerName: String = "gateway", baseURL: String, apiKeyVariable: String = "LITELLM_API_KEY") {
            self.providerName = providerName
            self.baseURL = baseURL
            self.apiKeyVariable = apiKeyVariable
        }
    }

    /// A loopback forwarder in front of the gateway. The child is told to use its address and given `placeholderKey`, so the real
    /// key is never in an environment an agent's shell can print.
    public struct Forwarder: Sendable, Equatable {
        public var baseURL: String
        public var placeholderKey: String

        public init(baseURL: String, placeholderKey: String = "forwarder") {
            self.baseURL = baseURL
            self.placeholderKey = placeholderKey
        }
    }

    public var executable: String
    public var gateway: Gateway
    public var forwarder: Forwarder?
    public var userDirectories: OpencodeSandbox.UserDirectories?
    public var home: URL

    public init(
        executable: String = "opencode", gateway: Gateway, forwarder: Forwarder? = nil,
        userDirectories: OpencodeSandbox.UserDirectories? = OpencodeSandbox.userDirectories(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.executable = executable
        self.gateway = gateway
        self.forwarder = forwarder
        self.userDirectories = userDirectories
        self.home = home
    }

    public var id: AgentProviderID { .opencode }

    public var capabilities: AgentCapabilities {
        AgentCapabilities(
            policies: [.readOnlyEvidence, .scopedCoding], resume: .none, streamsActivity: true, imageAttachments: false,
            structuredOutput: false, reportsUsage: true, hardDollarCap: false, confinesReads: true, confinesCodingReads: false)
    }

    /// `PATH`, `HOME` and the like, and the locale: nothing of the project's `env_pass`, no other provider's key.
    static let environmentNames: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TERM"]

    /// The directory under the request's output directory that holds this provider's per-run files.
    static func layout(for request: AgentRequest) -> OpencodeRunLayout {
        OpencodeRunLayout(root: request.outputDirectory.appendingPathComponent("opencode", isDirectory: true))
    }

    /// Everything an invocation is made of, decided and checked, before anything is written.
    private struct Prepared {
        var config: OpencodeConfig
        var coding: Bool
        var environment: [String: String]
        var executable: URL
        var arguments: [String]
        var layout: OpencodeRunLayout
    }

    private func prepared(for request: AgentRequest) throws -> Prepared {
        func refuse(_ why: String) -> AgentFailure { AgentFailure(.unsupportedCapability, why, retry: .afterFix) }
        guard request.spend == .timeoutOnly else {
            throw refuse("OpenCode cannot enforce a dollar limit; its requests are timeout-only.")
        }
        guard request.session == .none else { throw refuse("OpenCode keeps no conversation yet: each turn is a fresh process.") }
        guard request.grants.isEmpty else { throw refuse("Extra tool permissions are Claude's patterns; OpenCode takes none.") }
        guard request.images.isEmpty else { throw refuse("Images in an OpenCode turn are not supported yet.") }
        guard request.reasoningEffort == nil else {
            throw refuse("OpenCode takes no reasoning effort yet; remove it from the role.")
        }
        guard request.mcp == nil, request.readDirectories.isEmpty else {
            throw refuse("MCP tools and other readable checkouts are Claude's; OpenCode takes none.")
        }
        guard request.workingDirectory.path.hasPrefix("/") else {
            throw refuse("An OpenCode turn needs the checkout's absolute path.")
        }
        guard let model = request.model else {
            throw refuse("OpenCode needs a model: the gateway's name for it, such as sonnet-claude, set on the role.")
        }
        let coding = request.policy == .scopedCoding
        if coding {
            guard forwarder != nil, userDirectories != nil else {
                throw refuse(
                    "OpenCode cannot confine a shell by itself; a coding turn runs under macOS's sandbox with a local forwarder, "
                        + "and this machine or run has neither.")
            }
        }

        let config: OpencodeConfig
        do {
            config = try OpencodeConfig(
                policy: coding ? .coding : .readOnly, providerName: gateway.providerName, modelName: model,
                baseURL: forwarder?.baseURL ?? gateway.baseURL, apiKeyVariable: gateway.apiKeyVariable)
        } catch {
            throw AgentFailure(.authOrConfig, "\(error)", retry: .afterFix)
        }

        var environment = request.environment.filter {
            Self.environmentNames.contains($0.key) || $0.key.hasPrefix("LC_")
        }
        if let forwarder {
            environment[gateway.apiKeyVariable] = forwarder.placeholderKey
        } else if let key = request.environment[gateway.apiKeyVariable], !key.isEmpty {
            environment[gateway.apiKeyVariable] = key
        } else {
            throw AgentFailure(
                .authOrConfig, "\(gateway.apiKeyVariable) is not set, so OpenCode cannot reach the gateway.", retry: .afterFix)
        }
        let layout = Self.layout(for: request)
        environment.merge(layout.environment) { _, new in new }

        guard let found = ExecutableResolver.resolve(executable, searchPath: environment["PATH"]) else {
            throw AgentFailure(
                .missingExecutable, "Could not find \"\(executable)\" on PATH. Install OpenCode or set its path.",
                retry: .afterFix)
        }
        // The prompt is after `--`: without it a prompt that starts with dashes is read as a flag.
        let arguments = ["run", "--standalone", "--format", "json", "--archived", "-m", config.modelID, "--", request.prompt]
        return Prepared(
            config: config, coding: coding, environment: environment, executable: found, arguments: arguments, layout: layout)
    }

    private static func shown(_ arguments: [String]) -> [String] {
        Array(arguments[..<(arguments.firstIndex(of: "--") ?? arguments.count)])
    }

    /// The command as it is logged, without the prompt and without writing anything: the same checks as `invocation`.
    public func displayArguments(for request: AgentRequest) throws -> [String] {
        let plan = try prepared(for: request)
        let shown = Self.shown(plan.arguments)
        return plan.coding ? ["-f", plan.layout.profileFile.path, plan.executable.path] + shown : shown
    }

    public func invocation(for request: AgentRequest) throws -> AgentInvocation {
        let plan = try prepared(for: request)
        let shown = Self.shown(plan.arguments)
        do {
            try plan.layout.create()
            try plan.config.json().write(to: plan.layout.configFile, options: .atomic)
            guard plan.coding, let userDirectories else {
                return AgentInvocation(
                    executable: plan.executable.path, arguments: plan.arguments, environment: plan.environment,
                    displayArguments: shown)
            }
            func real(_ url: URL) -> URL { URL(fileURLWithPath: realpath(url.path, nil).map { String(cString: $0) } ?? url.path) }
            let profile = try OpencodeSandbox.profile(
                worktree: real(request.workingDirectory), scratch: real(plan.layout.scratch), state: real(plan.layout.state),
                user: userDirectories, denyReads: OpencodeSandbox.credentialDirectories(home: home))
            try profile.write(to: plan.layout.profileFile, atomically: true, encoding: .utf8)
            let wrapped = ["-f", plan.layout.profileFile.path, plan.executable.path] + plan.arguments
            return AgentInvocation(
                executable: "/usr/bin/sandbox-exec", arguments: wrapped, environment: plan.environment,
                displayArguments: ["-f", plan.layout.profileFile.path, plan.executable.path] + shown)
        } catch let failure as AgentFailure {
            throw failure
        } catch {
            throw AgentFailure(.authOrConfig, "Could not prepare the OpenCode run: \(error)", retry: .afterFix)
        }
    }

    public func makeDecoder(for request: AgentRequest) -> any AgentDecoder {
        OpencodeDecoder(purpose: request.purpose, maxRawBytes: request.limits.maxRawBytes)
    }
}
