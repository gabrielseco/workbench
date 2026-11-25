import Foundation

/// `opencode run` through the OpenCode adapter's read-only invocation, for the plan turn and the PR description: no shell and no edit
/// tool, reads confined to the folder it runs in, nothing of the person's own OpenCode setup. Its answer is the last text it said.
/// With `.none` it runs in an empty folder in the request's scratch, so it can read nothing of the checkout. No dollar cap: the
/// request's timeout bounds it, and its cost is what the gateway reported per step.
public struct OpencodeReadOnlyAgent: ReadOnlyAgent {
    public var executable: String
    public var gateway: OpencodeProvider.Gateway
    public var environment: [String: String]

    public init(executable: String = "opencode", gateway: OpencodeProvider.Gateway, environment: [String: String]) {
        self.executable = executable
        self.gateway = gateway
        self.environment = environment
    }

    /// Anything this agent hands back may end up in the event log (a failure becomes `plan.ended.reason`), and a gateway can echo the key
    /// it was given in an authentication error. The exact configured value is removed; a key too short to be one is left alone, as
    /// removing it would only damage ordinary words.
    func redacted(_ text: String) -> String {
        guard let key = environment[gateway.apiKeyVariable], key.count >= 8 else { return text }
        return text.replacingOccurrences(of: key, with: "[key removed]")
    }

    private var provider: OpencodeProvider { OpencodeProvider(executable: executable, gateway: gateway) }

    public func unavailable() -> String? {
        ExecutableResolver.resolve(executable, searchPath: environment["PATH"]) == nil ? "`\(executable)` was not found" : nil
    }

    /// The adapter's request; nil without a scratch folder, which the per-run files live in.
    func agentRequest(for request: ReadOnlyRequest) -> AgentRequest? {
        guard let scratch = request.scratch else { return nil }
        let empty = request.tools == .none
        return AgentRequest(
            provider: .opencode, model: request.model, prompt: request.prompt,
            workingDirectory: empty ? scratch.empty : request.workingDirectory, outputDirectory: scratch.url,
            policy: .readOnlyEvidence, spend: .timeoutOnly, purpose: empty ? .ship : .plan, environment: environment,
            limits: AgentLimits(timeout: request.timeout, maxLineBytes: 1 << 20), reasoningEffort: request.reasoningEffort)
    }

    public func shownArguments(for request: ReadOnlyRequest) -> [String] {
        guard let agentRequest = agentRequest(for: request) else { return [] }
        return (try? provider.displayArguments(for: agentRequest)) ?? []
    }

    public func run(_ request: ReadOnlyRequest, attach: @Sendable (ProcessRun) -> Void) async -> ReadOnlyAnswer {
        // What the gateway charged before a turn failed is still spent: it goes with the failure, so the log shows it.
        func failed(_ why: String, cost: Double? = nil) -> ReadOnlyAnswer {
            ReadOnlyAnswer(text: nil, costUSD: cost, failure: redacted(why))
        }
        guard let scratch = request.scratch, let agentRequest = agentRequest(for: request) else {
            return failed("opencode has no folder to keep its run in")
        }
        do { try scratch.prepare() } catch { return failed("the scratch folder could not be made: \(error)") }
        // Whatever it left running or wrote goes with the turn, also on a stop, a timeout or a failure.
        defer { scratch.clear() }
        // The key stays in a forwarder for the turn: this turn has no shell, but it has a code tool and reads text that may be hostile,
        // and what it says goes into the log.
        let session: OpencodeGatewaySession
        do {
            session = try OpencodeGatewaySession.start(gateway: gateway, executable: executable, environment: environment)
        } catch { return failed("\(error)") }
        defer { session.stop() }
        let adapter = session.provider
        let invocation: AgentInvocation
        do {
            if let refusal = agentRequest.validate(against: adapter) { throw refusal }
            invocation = try adapter.invocation(for: agentRequest)
        } catch { return failed((error as? AgentFailure)?.message ?? "\(error)") }

        var spawn = SpawnRequest(
            executable: URL(fileURLWithPath: invocation.executable), arguments: invocation.arguments,
            environment: invocation.environment, workingDirectory: agentRequest.workingDirectory, timeout: request.timeout)
        spawn.maxLineBytes = agentRequest.limits.maxLineBytes
        let run: ProcessRun
        do { run = try ProcessRunner.start(spawn) } catch { return failed("opencode could not be started") }
        attach(run)
        var decoder = adapter.makeDecoder(for: agentRequest)
        var exit: ProcessExit?
        for await event in run.events {
            switch event {
            case .line(let line): _ = decoder.consume(line: line)
            case .exited(let e): exit = e
            case .oversizedLine(let preview, let total): _ = decoder.consume(oversizedPreview: preview, totalBytes: total)
            case .started: break
            }
        }
        guard let exit else { return failed("opencode did not report how it ended") }
        let result = decoder.finish(exit: exit)
        let spent = result.usage?.costUSD
        // What the gateway said explains a failure better than the exit status does; a stop or a timeout is the caller's.
        if exit.cause == .natural, let failure = result.failure { return failed(failure.message, cost: spent) }
        if let why = ClaudeReadOnlyAgent.problem(exit, timeout: request.timeout, name: "opencode", turn: request.turn) {
            return failed(why, cost: spent)
        }
        if let failure = result.failure { return failed(failure.message, cost: spent) }
        guard result.outcome == .succeeded, case .text(let text)? = result.answer, !text.isEmpty else {
            return failed("opencode left no answer", cost: spent)
        }
        return ReadOnlyAnswer(text: redacted(text), costUSD: result.usage?.costUSD, failure: nil)
    }
}
