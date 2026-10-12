import Foundation

/// Everything that varies between turns. The tool set and flags come from `Config`.
public struct TurnRequest: Sendable, Equatable {
    public var sessionID: UUID
    /// False only for the first spawn of a thread (`--session-id`); true for every later one (`--resume`).
    public var resume: Bool
    public var budgetUSD: Decimal
    public var prompt: String
    public var appendSystemPrompt: String?

    public init(
        sessionID: UUID, resume: Bool, budgetUSD: Decimal, prompt: String, appendSystemPrompt: String? = nil
    ) {
        self.sessionID = sessionID
        self.resume = resume
        self.budgetUSD = budgetUSD
        self.prompt = prompt
        self.appendSystemPrompt = appendSystemPrompt
    }
}

public enum InvocationError: Error, Equatable, Sendable {
    case emptyPrompt
    case nonPositiveBudget
}

/// A fully resolved `claude` command line. Executed without a shell, so arguments are never re-parsed.
public struct ClaudeInvocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    /// For humans and logs only. Never execute this.
    public var displayCommand: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Config {
    /// The argv for one turn (docs/plan/P1-runner.md, "Turn lifecycle"; flags verified in the P1 spikes).
    ///
    /// - `--restricted` is always passed. It is what confines the file tools to the worktree; without it
    ///   a bare `Edit` in the allowed list can write anywhere (spike S3).
    /// - The prompt follows `--` because `--tools`, `--allowedTools` and `--disallowedTools` are variadic.
    /// - stdin must be `/dev/null` at spawn, or `claude` waits 3 seconds (spike S4/S5 notes).
    public func invocation(for turn: TurnRequest) throws -> ClaudeInvocation {
        guard !turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvocationError.emptyPrompt
        }
        guard turn.budgetUSD > 0 else { throw InvocationError.nonPositiveBudget }

        var args = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-prompts", "none", "--restricted",
        ]
        if safeMode { args += ["--safe-mode", "--disable-slash-commands"] }
        let session = turn.sessionID.uuidString.lowercased()
        args += turn.resume ? ["--resume", session] : ["--session-id", session]
        args += ["--max-budget-usd", NSDecimalNumber(decimal: turn.budgetUSD).stringValue]
        if let model { args += ["--model", model] }
        args += ["--tools"] + tools.available
        let allowed = effectiveAllowedTools
        if !allowed.isEmpty { args += ["--allowedTools"] + allowed }
        if !tools.denied.isEmpty { args += ["--disallowedTools"] + tools.denied }
        if let rules = turn.appendSystemPrompt, !rules.isEmpty { args += ["--append-system-prompt", rules] }
        args += ["--", turn.prompt]
        return ClaudeInvocation(executable: claudePath, arguments: args)
    }

    /// Variables always passed to `claude`. Deliberately small: no `SSH_AUTH_SOCK`, no cloud or token
    /// variables, so a model that talks its way past the allowlist still holds no credentials.
    /// `CLAUDE_CONFIG_DIR` is included because that is where the login lives.
    public static let baseEnvironmentNames: [String] = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR", "TERM", "CLAUDE_CONFIG_DIR",
    ]

    public func childEnvironment(from parent: [String: String]) -> [String: String] {
        let names = Set(Self.baseEnvironmentNames + envPass)
        return parent.filter { names.contains($0.key) || $0.key.hasPrefix("LC_") }
    }
}

public enum ExecutableResolver {
    /// Finds `name` the way a shell would. A name containing `/` is taken as a path.
    public static func resolve(_ name: String, searchPath: String?) -> URL? {
        let fm = FileManager.default
        if name.contains("/") {
            return fm.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil
        }
        for dir in (searchPath ?? "").split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue,
                fm.isExecutableFile(atPath: candidate.path)
            {
                return candidate
            }
        }
        return nil
    }
}
