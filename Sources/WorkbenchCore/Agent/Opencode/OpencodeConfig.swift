import Foundation

/// Why a value was refused before it reached an OpenCode config or profile.
public struct OpencodeSetupError: Error, Equatable, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}

/// The configuration file Workbench writes for one OpenCode run, and passes as `OPENCODE_CONFIG`. A run never depends on the person's
/// own `~/.config/opencode` (which differs on every machine) and never on an `opencode.json` in the checkout (the agent can write one
/// for its next turn): see `OpencodeRunLayout.environment`.
///
/// What the permission block can and cannot do was probed in `docs/plan/P28-capabilities.md`. Rules on OpenCode's own tools hold; rules
/// on `bash` match the text of a command and one wrapper (`bash -c`, `python3 -c`) gets past them, so a shell is only confined by the
/// sandbox (`OpencodeSandbox`), and a read-only turn gets no shell at all. Every rule is written out as an explicit `deny`: a rule that
/// is absent is not asked, it is allowed (no `external_directory` rule allowed a read and a write outside the checkout), and `ask` is
/// approved by `--auto`, which a run never passes.
public struct OpencodeConfig: Sendable, Equatable {
    public enum Policy: Sendable, Equatable {
        /// Reads, globs and greps inside the checkout; no edit tool, no shell, no network.
        case readOnly
        /// Edits and a shell in the checkout. The shell is only as confined as the process around it.
        case coding
    }

    public var policy: Policy
    /// The key under `provider` and the first half of `--model`: `gateway` in `gateway/sonnet-claude`.
    public var providerName: String
    public var modelName: String
    /// An OpenAI-compatible endpoint. Under the sandbox this is the loopback forwarder, never the real host.
    public var baseURL: String
    /// The environment variable the key is read from. The key itself is never written to the file.
    public var apiKeyVariable: String
    /// Other checkouts a coding turn's file tools may read (`read_also`), absolute. Only the sandbox keeps them unwritten.
    public var readDirectories: [String]

    public init(
        policy: Policy, providerName: String, modelName: String, baseURL: String, apiKeyVariable: String,
        readDirectories: [String] = []
    ) throws {
        func refuse(_ why: String) -> OpencodeSetupError { OpencodeSetupError(why) }
        guard providerName.range(of: #"^[a-z][a-z0-9-]{0,31}\z"#, options: .regularExpression) != nil else {
            throw refuse("The provider name \"\(providerName)\" must be lower case letters, digits and dashes.")
        }
        guard SafeNames.isModelName(modelName), !modelName.contains("/") else {
            throw refuse("The model name \"\(modelName)\" is not a valid model name (no slash: the provider is named apart).")
        }
        guard apiKeyVariable.range(of: #"^[A-Z][A-Z0-9_]{0,63}\z"#, options: .regularExpression) != nil else {
            throw refuse("The key variable \"\(apiKeyVariable)\" must be an upper case environment variable name.")
        }
        guard let url = URLComponents(string: baseURL), let scheme = url.scheme, ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            !baseURL.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F })
        else {
            throw refuse("The base URL must be an http or https URL with a host, and no credentials, query, fragment or spaces.")
        }
        // A rule is a pattern, so a folder whose name holds pattern characters would open more than itself.
        guard readDirectories.isEmpty || policy == .coding else {
            throw refuse("Other checkouts are given to a coding turn only.")
        }
        for folder in readDirectories {
            let pattern = "*?[]{}".unicodeScalars
            let bad = folder.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || pattern.contains($0) }
            guard folder.hasPrefix("/"), folder != "/", !folder.hasSuffix("/"), !bad else {
                throw refuse(
                    "The folder \"\(folder)\" cannot be named in a permission rule: an absolute path without *, ?, [, ], { or }.")
            }
        }
        self.readDirectories = readDirectories
        self.policy = policy
        self.providerName = providerName
        self.modelName = modelName
        self.baseURL = baseURL
        self.apiKeyVariable = apiKeyVariable
    }

    /// What goes after `-m`.
    public var modelID: String { "\(providerName)/\(modelName)" }

    private static let denied = "deny"
    private static let allowed = "allow"

    /// The permission block. Every key OpenCode knows is set, so nothing is left to its default.
    var permission: [String: Any] {
        var rules: [String: Any] = [
            "read": Self.allowed, "glob": Self.allowed, "grep": Self.allowed, "list": Self.allowed,
            "webfetch": Self.denied, "websearch": Self.denied, "external_directory": Self.denied, "task": Self.denied,
            "skill": Self.denied, "question": Self.denied, "todowrite": Self.denied, "lsp": Self.denied, "doom_loop": Self.denied,
        ]
        switch policy {
        case .readOnly:
            rules["edit"] = Self.denied
            rules["bash"] = ["*": Self.denied]
        case .coding:
            // The last matching rule wins and the keys are written sorted, so `*` comes before every path.
            if !readDirectories.isEmpty {
                var outside = ["*": Self.denied]
                for folder in readDirectories {
                    for pattern in [folder, folder + "/*", folder + "/**"] { outside[pattern] = Self.allowed }
                }
                rules["external_directory"] = outside
            }
            rules["edit"] = Self.allowed
            // The patterns only name what is refused with a clear message; the sandbox is what stops a wrapped command.
            rules["bash"] = [
                "*": Self.allowed, "git push*": Self.denied, "git commit*": Self.denied, "curl*": Self.denied,
                "wget*": Self.denied,
            ]
        }
        return rules
    }

    /// The file, with keys in a fixed order so the same input is the same bytes.
    public func json() throws -> Data {
        let provider: [String: Any] = [
            providerName: [
                "npm": "@ai-sdk/openai-compatible", "name": providerName,
                "options": ["baseURL": baseURL, "apiKey": "{env:\(apiKeyVariable)}"],
                "models": [modelName: ["name": modelName]],
            ] as [String: Any]
        ]
        let config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "provider": provider,
            // Only this provider: no other one in the person's setup is reachable, and the title model is the same one.
            "enabled_providers": [providerName],
            "model": modelID, "small_model": modelID,
            "permission": permission,
            "share": "disabled", "autoupdate": false, "plugin": [String](),
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }
}

/// Where one OpenCode run keeps what it writes, and the environment that points it there. Everything is under `root` except the
/// worktree: the run's state and its scratch directory are the only places besides the worktree a sandboxed run may write, and the
/// config and the profile sit beside them, unwritable, so a turn cannot rewrite its own rules.
public struct OpencodeRunLayout: Sendable, Equatable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public var configFile: URL { root.appendingPathComponent("opencode.json") }
    public var profileFile: URL { root.appendingPathComponent("sandbox.sb") }
    /// `TMPDIR` for the turn. Tools that ask macOS for the temp directory instead of `TMPDIR` are covered in `OpencodeSandbox`.
    public var scratch: URL { root.appendingPathComponent("scratch", isDirectory: true) }
    /// OpenCode's own config, data, state and cache directories (the `XDG_*` ones): its session database and logs.
    public var state: URL { root.appendingPathComponent("state", isDirectory: true) }

    func xdg(_ name: String) -> URL { state.appendingPathComponent(name, isDirectory: true) }

    /// Added to the child's environment. `PATH`, `HOME` and the key come from the provider's allow-list, not from here.
    public var environment: [String: String] {
        [
            "XDG_CONFIG_HOME": xdg("config").path, "XDG_DATA_HOME": xdg("data").path, "XDG_STATE_HOME": xdg("state").path,
            "XDG_CACHE_HOME": xdg("cache").path, "OPENCODE_CONFIG": configFile.path,
            // A checked-in `opencode.json` loosened every rule in the probes; the worktree is the agent's own output.
            "OPENCODE_DISABLE_PROJECT_CONFIG": "1", "TMPDIR": scratch.path,
        ]
    }

    /// The directories OpenCode writes to, so the first run does not depend on it creating them.
    public func create() throws {
        let fm = FileManager.default
        for dir in [scratch, xdg("config"), xdg("data"), xdg("state"), xdg("cache")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
