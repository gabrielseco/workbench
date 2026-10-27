import Foundation

/// What a read-only turn may use besides its prompt.
public enum ReadOnlyTools: Sendable, Equatable {
    /// Reading the request's folder (the plan turn).
    case read
    /// Nothing: everything it may use is in the prompt (the PR description and its refresh).
    case none
}

/// One read-only question to a coding agent: a prompt, a folder it may read, a model, a budget, a deadline.
public struct ReadOnlyRequest: Sendable, Equatable {
    public var prompt: String
    public var workingDirectory: URL
    public var model: String?
    public var budget: Decimal
    public var timeout: TimeInterval
    /// `--effort`; nil leaves the agent's own setting.
    public var reasoningEffort: String?
    public var tools: ReadOnlyTools = .read
    /// A folder outside what the turn reads that it owns while it runs (a Codex answer goes there, and a Codex turn with no
    /// tools runs in an empty folder inside it). Made fresh and removed by the agent; nil for an agent that needs none.
    public var scratch: TurnScratch?
    /// What the turn is called when it is stopped.
    public var turn = "plan"
    /// Claude's `--session-id`, the same in the logged command and the one that runs.
    public var sessionID = UUID()
}

/// What came back. `text` is set when the agent answered; `failure` says why it did not (never both).
public struct ReadOnlyAnswer: Sendable, Equatable {
    public var text: String?
    /// Nil when the provider reported none (Codex): unknown, never 0.
    public var costUSD: Double?
    public var failure: String?
}

/// The seam between what Workbench asks of a read-only agent and which agent answers. The plan turn and the PR
/// description turns know only this; each provider is a conformance.
public protocol ReadOnlyAgent: Sendable {
    /// Why the agent cannot run at all (not installed), nil when it can.
    func unavailable() -> String?
    /// The command as it is logged: everything but the prompt.
    func shownArguments(for request: ReadOnlyRequest) -> [String]
    /// Runs it to the end. `attach` is called with the live process so the caller can stop it.
    func run(_ request: ReadOnlyRequest, attach: @Sendable (ProcessRun) -> Void) async -> ReadOnlyAnswer
}

extension Config {
    /// The read-only agent for `provider`, nil for one no adapter exists for.
    public func readOnlyAgent(_ provider: AgentProviderID, environment: [String: String]) -> (any ReadOnlyAgent)? {
        switch provider {
        case .claude: ClaudeReadOnlyAgent(config: self, environment: environment)
        case .codex: CodexReadOnlyAgent(executable: executable(for: .codex), environment: environment)
        default: nil
        }
    }
}

/// A folder a read-only turn owns while it runs. It names the process that made it, so one a killed Workbench left is
/// told from one in use and cleared by the next command.
public struct TurnScratch: Sendable, Equatable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// The empty folder a turn with no tools runs in.
    var empty: URL { url.appendingPathComponent("empty", isDirectory: true) }
    var answer: URL { url.appendingPathComponent("answer.txt") }
    private var owner: URL { url.appendingPathComponent("owner.json") }

    /// Ends what a killed turn left running in it, then makes it again, empty and owned by this process.
    func prepare() throws {
        clear()
        try FileManager.default.createDirectory(
            at: empty, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
        let me = ProcessTree.member(for: getpid())
        let info: [String: Any] = [
            "pid": getpid(), "started_seconds": me?.startSeconds ?? 0, "started_micros": me?.startMicros ?? 0,
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]).write(to: owner, options: .atomic)
    }

    /// Ends what runs in it and removes it.
    func clear() {
        OrphanSweeper.sweep(inside: url)
        try? FileManager.default.removeItem(at: url)
    }

    /// Clears it when the process that made it is gone; one in use is left alone.
    func clearIfAbandoned() {
        guard FileManager.default.fileExists(atPath: url.path), !ownerIsAlive else { return }
        clear()
    }

    private var ownerIsAlive: Bool {
        guard let data = try? Data(contentsOf: owner),
            let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pid = (info["pid"] as? NSNumber)?.int32Value,
            let seconds = (info["started_seconds"] as? NSNumber)?.uint64Value,
            let micros = (info["started_micros"] as? NSNumber)?.uint64Value
        else { return false }
        return ProcessTree.isAlive(ProcessMember(pid: pid, startSeconds: seconds, startMicros: micros))
    }
}

/// `claude -p` in its own session. With `.read` it has only `Read`, `Grep` and `Glob`, confined to the request's folder;
/// with `.none` it has no tools and is the PR description's command, unchanged.
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
    public func arguments(for request: ReadOnlyRequest, sessionID given: UUID? = nil) -> [String] {
        let sessionID = given ?? request.sessionID
        if request.tools == .none {
            return PRDescriber.arguments(
                safeMode: config.safeMode, model: request.model, effort: request.reasoningEffort, budget: request.budget,
                prompt: request.prompt, sessionID: sessionID)
        }
        var args = [
            "-p", "--output-format", "json", "--permission-prompts", "none", "--restricted",
            "--session-id", sessionID.uuidString.lowercased(),
            "--max-budget-usd", NSDecimalNumber(decimal: request.budget).stringValue,
        ]
        // Always: `safe_mode = false` lets a project's hooks and plugins into a run, and this turn is read-only.
        args += ["--safe-mode", "--disable-slash-commands"]
        if let model = request.model { args += ["--model", model] }
        if let effort = request.reasoningEffort { args += ["--effort", effort] }
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
        if let why = Self.problem(exit, timeout: request.timeout, turn: request.turn) {
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

    /// Why a run produced no answer to read, nil when it ended on its own with status 0.
    static func problem(
        _ exit: ProcessExit?, timeout: TimeInterval, name: String = "claude", turn: String = "plan"
    ) -> String? {
        guard let exit else { return "\(name) did not report how it ended" }
        switch exit.cause {
        case .stopped: return "the \(turn) was stopped"
        case .timedOut: return "\(name) did not answer within \(Int(timeout))s"
        case .natural: break
        }
        switch exit.termination {
        case .exited(0): return nil
        case .exited(let code): return "\(name) exited with status \(code)"
        case .signaled(let signal): return "\(name) was ended by signal \(signal)"
        case .lost: return "\(name) ended in a way that was not recorded"
        }
    }
}

/// `codex exec` through the Codex adapter's read-only invocation, the judge's: read-only sandbox, nothing approved, the
/// user's exec-policy rules ignored, only Codex's own variables. Its answer is the file `-o` names, in the request's
/// scratch folder. With `.none` it runs in an empty folder there, so it can read nothing of the checkout. No dollar
/// cap: the request's timeout bounds it, and its cost is unknown.
public struct CodexReadOnlyAgent: ReadOnlyAgent {
    public var executable: String
    public var environment: [String: String]

    public init(executable: String = "codex", environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    private var provider: CodexProvider { CodexProvider(executable: executable) }

    public func unavailable() -> String? {
        ExecutableResolver.resolve(executable, searchPath: environment["PATH"]) == nil ? "`\(executable)` was not found" : nil
    }

    /// The adapter's request; nil without a scratch folder, which the answer needs.
    func agentRequest(for request: ReadOnlyRequest) -> AgentRequest? {
        guard let scratch = request.scratch else { return nil }
        let empty = request.tools == .none
        var built = AgentRequest(
            provider: .codex, model: request.model, prompt: request.prompt,
            workingDirectory: empty ? scratch.empty : request.workingDirectory, outputDirectory: scratch.url,
            policy: .readOnlyEvidence, spend: .timeoutOnly, purpose: empty ? .ship : .plan, environment: environment,
            limits: AgentLimits(timeout: request.timeout, maxLineBytes: 1 << 20), answerFile: scratch.answer,
            reasoningEffort: request.reasoningEffort)
        built.outsideRepository = empty
        return built
    }

    public func shownArguments(for request: ReadOnlyRequest) -> [String] {
        guard let agentRequest = agentRequest(for: request) else { return [] }
        return (try? provider.invocation(for: agentRequest).displayArguments) ?? []
    }

    public func run(_ request: ReadOnlyRequest, attach: @Sendable (ProcessRun) -> Void) async -> ReadOnlyAnswer {
        func failed(_ why: String) -> ReadOnlyAnswer { ReadOnlyAnswer(text: nil, costUSD: nil, failure: why) }
        guard let scratch = request.scratch, let agentRequest = agentRequest(for: request) else {
            return failed("codex has no folder to write its answer to")
        }
        let invocation: AgentInvocation
        do {
            if let refusal = agentRequest.validate(against: provider) { throw refusal }
            invocation = try provider.invocation(for: agentRequest)
        } catch { return failed((error as? AgentFailure)?.message ?? "\(error)") }
        guard let codex = ExecutableResolver.resolve(executable, searchPath: invocation.environment["PATH"]) else {
            return failed(unavailable() ?? "`\(executable)` was not found")
        }
        do { try scratch.prepare() } catch { return failed("the scratch folder could not be made: \(error)") }
        // Whatever it left running or wrote goes with the turn, also on a stop, a timeout or a failure.
        defer { scratch.clear() }

        var spawn = SpawnRequest(
            executable: codex, arguments: invocation.arguments, environment: invocation.environment,
            workingDirectory: agentRequest.workingDirectory, timeout: request.timeout)
        spawn.maxLineBytes = agentRequest.limits.maxLineBytes
        let run: ProcessRun
        do { run = try ProcessRunner.start(spawn) } catch { return failed("codex could not be started") }
        attach(run)
        var decoder = provider.makeDecoder(for: agentRequest)
        var exit: ProcessExit?
        for await event in run.events {
            switch event {
            case .line(let line): _ = decoder.consume(line: line)
            case .exited(let e): exit = e
            case .started, .oversizedLine: break
            }
        }
        if let why = ClaudeReadOnlyAgent.problem(exit, timeout: request.timeout, name: "codex", turn: request.turn) {
            return failed(why)
        }
        if let exit, let failure = decoder.finish(exit: exit).failure { return failed(failure.message) }
        guard let text = ThreadService.readAnswer(scratch.answer) else { return failed("codex left no answer") }
        return ReadOnlyAnswer(text: text, costUSD: nil, failure: nil)
    }
}
