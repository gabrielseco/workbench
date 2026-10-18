import Foundation

/// One read-only question to a coding agent: a prompt, a folder it may read, a model, a budget, a deadline.
public struct ReadOnlyRequest: Sendable, Equatable {
    public var prompt: String
    public var workingDirectory: URL
    public var model: String?
    public var budget: Decimal
    public var timeout: TimeInterval
}

/// What came back. `text` is set when the agent answered; `failure` says why it did not (never both).
public struct ReadOnlyAnswer: Sendable, Equatable {
    public var text: String?
    public var costUSD: Double?
    public var failure: String?
}

/// The seam between what Workbench asks of a read-only agent and which agent answers. The plan turn knows only
/// this; a provider other than Claude is a new conformance, not a change to the plan.
public protocol ReadOnlyAgent: Sendable {
    /// Why the agent cannot run at all (not installed), nil when it can.
    func unavailable() -> String?
    /// The command as it is logged: everything but the prompt.
    func shownArguments(for request: ReadOnlyRequest) -> [String]
    /// Runs it to the end. `attach` is called with the live process so the caller can stop it.
    func run(_ request: ReadOnlyRequest, attach: @Sendable (ProcessRun) -> Void) async -> ReadOnlyAnswer
}

/// `claude -p` with only `Read`, `Grep` and `Glob`, confined to the request's folder, in its own session.
public struct ClaudeReadOnlyAgent: ReadOnlyAgent {
    public static let tools = ["Read", "Grep", "Glob"]

    public var config: Config
    public var environment: [String: String]

    public init(config: Config, environment: [String: String]) {
        self.config = config
        self.environment = environment
    }

    public func unavailable() -> String? {
        ExecutableResolver.resolve(config.claudePath, searchPath: environment["PATH"]) == nil
            ? "`\(config.claudePath)` was not found" : nil
    }

    /// The argv. No `--permission-mode` (the tool list is what makes it read-only), no `--resume`, no `Bash`,
    /// `Edit` or `Write`. The prompt follows `--` because the tool flags are variadic.
    public func arguments(for request: ReadOnlyRequest, sessionID: UUID = UUID()) -> [String] {
        var args = [
            "-p", "--output-format", "json", "--permission-prompts", "none", "--restricted",
            "--session-id", sessionID.uuidString.lowercased(),
            "--max-budget-usd", NSDecimalNumber(decimal: request.budget).stringValue,
        ]
        // Always: `safe_mode = false` lets a project's hooks and plugins into a run, and this turn is read-only.
        args += ["--safe-mode", "--disable-slash-commands"]
        if let model = request.model { args += ["--model", model] }
        args += ["--tools"] + Self.tools + ["--allowedTools"] + Self.tools
        args += ["--", request.prompt]
        return args
    }

    public func shownArguments(for request: ReadOnlyRequest) -> [String] {
        PRDescriber.displayArguments(arguments(for: request))
    }

    public func run(_ request: ReadOnlyRequest, attach: @Sendable (ProcessRun) -> Void) async -> ReadOnlyAnswer {
        guard let claude = ExecutableResolver.resolve(config.claudePath, searchPath: environment["PATH"]) else {
            return ReadOnlyAnswer(text: nil, costUSD: nil, failure: unavailable())
        }
        var spawn = SpawnRequest(
            executable: claude, arguments: arguments(for: request),
            environment: config.childEnvironment(from: environment), workingDirectory: request.workingDirectory,
            timeout: request.timeout)
        spawn.maxLineBytes = 1 << 20
        let run: ProcessRun
        do { run = try ProcessRunner.start(spawn) } catch {
            return ReadOnlyAnswer(text: nil, costUSD: nil, failure: "claude could not be started")
        }
        attach(run)
        var lines: [String] = []
        var exit: ProcessExit?
        for await event in run.events {
            switch event {
            case .line(let line): lines.append(line)
            case .exited(let e): exit = e
            case .started, .oversizedLine: break
            }
        }
        if let why = Self.problem(exit, timeout: request.timeout) {
            return ReadOnlyAnswer(text: nil, costUSD: nil, failure: why)
        }
        guard let outer = PRDescriber.object(from: lines.joined(separator: "\n")) else {
            return ReadOnlyAnswer(text: nil, costUSD: nil, failure: "the answer was not JSON")
        }
        let cost = (outer["total_cost_usd"] as? NSNumber)?.doubleValue
        if outer["is_error"] as? Bool == true {
            return ReadOnlyAnswer(text: nil, costUSD: cost, failure: "claude reported an error")
        }
        guard let text = outer["result"] as? String else {
            return ReadOnlyAnswer(text: nil, costUSD: cost, failure: "the answer had no result")
        }
        return ReadOnlyAnswer(text: text, costUSD: cost, failure: nil)
    }

    /// Why a `claude` run produced no answer to read, nil when it ended on its own with status 0.
    static func problem(_ exit: ProcessExit?, timeout: TimeInterval) -> String? {
        guard let exit else { return "claude did not report how it ended" }
        switch exit.cause {
        case .stopped: return "the plan was stopped"
        case .timedOut: return "claude did not answer within \(Int(timeout))s"
        case .natural: break
        }
        switch exit.termination {
        case .exited(0): return nil
        case .exited(let code): return "claude exited with status \(code)"
        case .signaled(let signal): return "claude was ended by signal \(signal)"
        case .lost: return "claude ended in a way that was not recorded"
        }
    }
}
