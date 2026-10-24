import Foundation

/// One child process, fully decided. Executed without a shell.
public struct AgentInvocation: Sendable, Equatable {
    /// A name looked up on `environment["PATH"]`, or a path.
    public var executable: String
    public var arguments: [String]
    /// Exactly what the child sees: the adapter's pick from the request's allowed environment.
    public var environment: [String: String]
    /// For logs: no prompt text, no credentials.
    public var displayArguments: [String]
    /// A file the provider is told to write its answer to, when it has one.
    public var answerFile: URL?

    public init(
        executable: String, arguments: [String], environment: [String: String], displayArguments: [String]? = nil,
        answerFile: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.displayArguments = displayArguments ?? arguments
        self.answerFile = answerFile
    }
}

/// What the provider's output says, once the process has ended.
public struct AgentDecoderResult: Sendable, Equatable {
    public var outcome: AgentCompletion.ProviderOutcome
    public var answer: AgentAnswer?
    public var session: AgentSessionHandle?
    public var usage: AgentUsage?
    /// A failure the provider's own output explains (capacity, auth). Process-level ones are added by the runner.
    public var failure: AgentFailure?
    public var permissionDenials: [AgentDenial]
    public var permissionDenialCount: Int
    /// A last line the process layer kept aside past the output limit and the decoder used because the stream
    /// had no result of its own. The recorder gets it after the stream, so the log holds what the decision used.
    public var lateLine: String?

    public init(
        outcome: AgentCompletion.ProviderOutcome, answer: AgentAnswer? = nil, session: AgentSessionHandle? = nil,
        usage: AgentUsage? = nil, failure: AgentFailure? = nil, permissionDenials: [AgentDenial] = [],
        permissionDenialCount: Int = 0, lateLine: String? = nil
    ) {
        self.permissionDenials = permissionDenials
        self.permissionDenialCount = permissionDenialCount
        self.lateLine = lateLine
        self.outcome = outcome
        self.answer = answer
        self.session = session
        self.usage = usage
        self.failure = failure
    }
}

/// What the process layer saw, before any decoding.
public enum AgentRawLine: Sendable, Equatable {
    case line(String)
    /// Over the size limit: its start and its real size.
    case oversized(preview: String, totalBytes: Int)
    /// The last line the process layer kept aside past the output limit, delivered after the stream when the
    /// decoder used it (`AgentDecoderResult.lateLine`).
    case late(String)
}

/// Receives every raw line, in order and losslessly, with the activity the decoder drew from it. This is how a
/// stage keeps the verbatim record (the event log) that the bounded activity stream cannot promise. Each call is
/// awaited before the next line is read; a throw stops the child, and the rest of its output is drained, not recorded.
public protocol AgentRecorder: Sendable {
    func record(_ line: AgentRawLine, activity: [AgentActivity]) async throws
}

/// Reads one child's stdout. Created per execution, so it may keep state.
public protocol AgentDecoder: Sendable {
    /// One complete line. Returns the activity it carries, possibly none.
    mutating func consume(line: String) -> [AgentActivity]
    /// A line over the size limit was dropped after its first bytes. Required: whether losing it makes the answer
    /// unusable (a lost result record) or harmless (a long assistant message) is the provider's call, and a
    /// decoder that ignores it must say so by implementing it.
    mutating func consume(oversizedPreview preview: String, totalBytes: Int) -> [AgentActivity]
    /// The process ended (`exit.stderrTail` is the end of its stderr). Called exactly once.
    mutating func finish(exit: ProcessExit) -> AgentDecoderResult
}

/// An adapter: argv, environment, output decoding. It knows no criteria, review rounds or workflow state, and
/// never spawns, sleeps or retries (spec: docs/plan/P9-agent-providers.md, "Boundaries").
public protocol AgentProvider: Sendable {
    var id: AgentProviderID { get }
    var capabilities: AgentCapabilities { get }
    /// Builds the invocation for a request that already passed `AgentRequest.validate`.
    func invocation(for request: AgentRequest) throws -> AgentInvocation
    func makeDecoder(for request: AgentRequest) -> any AgentDecoder
}

extension AgentRequest {
    /// The refusals that come before any process or spend: a combination the adapter cannot honour is an error,
    /// never a weaker policy and never another provider.
    public func validate(against provider: any AgentProvider) -> AgentFailure? {
        let caps = provider.capabilities
        func refuse(_ why: String) -> AgentFailure { AgentFailure(.unsupportedCapability, why, retry: .afterFix) }

        guard self.provider == provider.id else {
            return refuse("The request names \(self.provider) but the adapter is \(provider.id).")
        }
        guard caps.policies.contains(policy) else {
            return refuse("\(provider.id) has no verified controls for \(policy.rawValue); it is not used for it.")
        }
        if case .hardCap = spend, !caps.hardDollarCap {
            if purpose == .coding {
                return refuse(
                    "\(provider.id) cannot enforce a dollar limit, and this goal has a budget_usd. "
                        + "Change the goal to `spend_policy: timeout_only` (and remove budget_usd), then approve it again.")
            }
            return refuse(
                "\(provider.id) cannot enforce a dollar limit. "
                    + "Choose a timeout-only spending policy explicitly, or another provider.")
        }
        if !images.isEmpty, !caps.imageAttachments {
            return refuse("\(provider.id) cannot take images, and there is no text substitute for visual evidence.")
        }
        let lim = limits
        if lim.timeout <= 0 || lim.maxLineBytes <= 0 || lim.maxOutputBytes <= 0 || lim.maxBufferedActivity <= 0
            || lim.maxRawBytes <= 0 {
            return refuse("Every limit (timeout, line, output, buffered activity, raw bytes) must be positive.")
        }
        if let model, model.isEmpty || !SafeNames.isModelName(model) {
            return refuse("The model name \"\(model)\" is not a valid model name.")
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return refuse("The prompt is empty.")
        }
        switch session {
        case .none:
            break
        case .start:
            if caps.resume == .none { return refuse("\(provider.id) keeps no conversation; use a one-shot request.") }
        case .resume(let handle):
            if caps.resume == .none { return refuse("\(provider.id) cannot resume a conversation.") }
            if handle.provider != provider.id {
                return refuse("A \(handle.provider) session cannot be resumed on \(provider.id).")
            }
            if handle.purpose != purpose {
                return refuse("A \(handle.purpose.rawValue) session cannot be resumed for \(purpose.rawValue).")
            }
        }
        return nil
    }
}
