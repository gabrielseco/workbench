import Foundation

/// P9: what a stage asks of an agent and what comes back, in terms no provider's CLI leaks into.
/// Orchestration (run, judge, review, goal drafting) builds an `AgentRequest`; an `AgentProvider` turns it
/// into one child process; `AgentRunner` runs that child over `ProcessRunner`. See docs/plan/P9-agent-providers.md.

/// A provider's stable name: `claude`, `codex`. Built-in providers only, so it is checked like any name
/// that reaches a path or a log.
public struct AgentProviderID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard rawValue.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public static let claude = AgentProviderID("claude")!  // swiftlint:disable:this force_unwrapping
    public static let codex = AgentProviderID("codex")!  // swiftlint:disable:this force_unwrapping
}

/// What the agent may do. Orchestration picks one; the adapter translates it to the provider's own tested
/// controls. No Workbench permission engine sits behind it.
public enum AgentPolicy: String, Sendable, Codable, CaseIterable {
    /// Edit and run the project's allowed tools inside the worktree. Nothing leaves it.
    case scopedCoding
    /// No repository writes and no posting: a judge or reviewer looking at prepared evidence.
    case readOnlyEvidence
}

/// How a provider keeps a conversation across processes.
public enum AgentResumeSupport: String, Sendable, Codable {
    /// Workbench chooses the id before the first spawn (Claude `--session-id`).
    case callerSuppliedID
    /// The provider returns the id in its output (Codex `thread.started`).
    case returnedID
    case none
}

/// What an adapter really does, from probes (docs/plan/P9-capabilities.md), not what a CLI might one day do.
public struct AgentCapabilities: Sendable, Equatable {
    public var policies: Set<AgentPolicy>
    public var resume: AgentResumeSupport
    public var streamsActivity: Bool
    public var imageAttachments: Bool
    public var structuredOutput: Bool
    public var reportsUsage: Bool
    /// A dollar limit the provider itself enforces. A timeout is not one.
    public var hardDollarCap: Bool
    /// Whether a read-only turn cannot read outside the working directory.
    public var confinesReads: Bool

    public init(
        policies: Set<AgentPolicy>, resume: AgentResumeSupport, streamsActivity: Bool = false,
        imageAttachments: Bool = false, structuredOutput: Bool = false, reportsUsage: Bool = false,
        hardDollarCap: Bool = false, confinesReads: Bool = false
    ) {
        self.policies = policies
        self.resume = resume
        self.streamsActivity = streamsActivity
        self.imageAttachments = imageAttachments
        self.structuredOutput = structuredOutput
        self.reportsUsage = reportsUsage
        self.hardDollarCap = hardDollarCap
        self.confinesReads = confinesReads
    }
}

/// An opaque conversation handle. Qualified by provider and purpose so it cannot be handed to another
/// provider or reused by a different job (a judge never resumes the coder).
public struct AgentSessionHandle: Hashable, Sendable, Codable {
    public enum Purpose: String, Sendable, Codable { case coding, goal, judge, review, plan, ship }

    public var provider: AgentProviderID
    public var purpose: Purpose
    public var value: String

    public init(provider: AgentProviderID, purpose: Purpose, value: String) {
        self.provider = provider
        self.purpose = purpose
        self.value = value
    }
}

public enum AgentSessionIntent: Sendable, Equatable {
    /// One-shot: no conversation is kept and none can be resumed.
    case none
    /// Start a conversation. `proposed` is used when the provider accepts a caller-chosen id.
    case start(proposed: String?)
    case resume(AgentSessionHandle)
}

/// How a request's spending is bounded.
public enum AgentSpend: Sendable, Equatable {
    /// A hard dollar limit the provider must enforce; refused on an adapter that cannot.
    case hardCap(Decimal)
    /// No dollar cap: only the deadline bounds it. The approval for that lives with the caller (the goal's
    /// `spend_policy` or `agents.<job>.allow_unpriced`); the runner only checks it was asked for explicitly.
    case timeoutOnly
}

public struct AgentLimits: Sendable, Equatable {
    public var timeout: TimeInterval
    public var maxLineBytes: Int
    public var maxOutputBytes: Int
    /// Activity not yet read by the consumer. Past it the oldest are dropped and counted, never queued.
    public var maxBufferedActivity: Int
    /// Raw text kept on an activity item or a failure message.
    public var maxRawBytes: Int
    /// After SIGTERM, how long before SIGKILL.
    public var killGrace: TimeInterval

    public init(
        timeout: TimeInterval, maxLineBytes: Int = 1 << 20, maxOutputBytes: Int = 64 << 20,
        maxBufferedActivity: Int = 1024, maxRawBytes: Int = 4096, killGrace: TimeInterval = 5
    ) {
        self.killGrace = killGrace
        self.timeout = timeout
        self.maxLineBytes = maxLineBytes
        self.maxOutputBytes = maxOutputBytes
        self.maxBufferedActivity = maxBufferedActivity
        self.maxRawBytes = maxRawBytes
    }
}

/// Everything an adapter needs to build one invocation. Bounded text only: the prompt is already prepared
/// (and sized) by the stage.
public struct AgentRequest: Sendable, Equatable {
    public var provider: AgentProviderID
    public var model: String?
    /// How hard the model thinks (`low` … `max`); nil is the provider's own setting. Read-only calls only.
    public var reasoningEffort: String?
    public var prompt: String
    public var images: [URL]
    public var workingDirectory: URL
    /// Where the adapter may write its own answer or transcript files: outside the checkout it works in.
    public var outputDirectory: URL
    public var policy: AgentPolicy
    public var spend: AgentSpend
    public var session: AgentSessionIntent
    public var purpose: AgentSessionHandle.Purpose
    /// The environment the stage allows. An adapter takes only the variables its provider needs.
    public var environment: [String: String]
    public var limits: AgentLimits
    /// Standing rules for the agent, appended to its system prompt where the provider has one.
    public var rules: String?
    /// Extra permissions the user granted this thread, as the provider's own tool patterns. Only for
    /// `scopedCoding`; the adapter never widens them and never revives one the project denies.
    public var grants: [String]
    /// Files in `workingDirectory` a `readOnlyEvidence` agent may open, by name. With none it has no tools at all.
    public var evidenceFiles: [String]
    /// Where an adapter that has the provider write its answer to a file (Codex `-o`) puts it: inside
    /// `outputDirectory`, so outside the checkout the agent works in.
    public var answerFile: URL?
    /// The working directory is an empty scratch folder outside any repository, which Codex otherwise refuses to start in.
    public var outsideRepository = false
    /// Other checkouts a Claude coding turn may read, never write (`ReadAlso`).
    public var readDirectories: [URL] = []

    public init(
        provider: AgentProviderID, model: String? = nil, prompt: String, images: [URL] = [],
        workingDirectory: URL, outputDirectory: URL, policy: AgentPolicy, spend: AgentSpend,
        session: AgentSessionIntent = .none, purpose: AgentSessionHandle.Purpose,
        environment: [String: String], limits: AgentLimits, rules: String? = nil, grants: [String] = [],
        evidenceFiles: [String] = [], answerFile: URL? = nil, reasoningEffort: String? = nil
    ) {
        self.reasoningEffort = reasoningEffort
        self.answerFile = answerFile
        self.evidenceFiles = evidenceFiles
        self.rules = rules
        self.grants = grants
        self.provider = provider
        self.model = model
        self.prompt = prompt
        self.images = images
        self.workingDirectory = workingDirectory
        self.outputDirectory = outputDirectory
        self.policy = policy
        self.spend = spend
        self.session = session
        self.purpose = purpose
        self.environment = environment
        self.limits = limits
    }
}

public struct AgentUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    /// As the provider reported it (a float, and the log keeps it as one). Unknown stays nil: it is never 0.
    public var costUSD: Double?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil, costUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.costUSD = costUSD
    }
}

/// One thing the agent did, normalized. An event the adapter does not understand is kept as `.unknown`, with
/// its provider and a bounded copy of the original line, rather than dropped.
public enum AgentActivity: Sendable, Equatable {
    case started(pid: Int32)
    case text(String)
    case tool(name: String, summary: String)
    case permissionDenied(tool: String)
    case usage(AgentUsage)
    case session(AgentSessionHandle)
    case diagnostic(String)
    case unknown(provider: AgentProviderID, raw: String)
    /// Activity the consumer was too slow to read, dropped oldest first.
    case dropped(count: Int)
}

public enum AgentRetry: String, Sendable, Codable {
    /// Same input will fail the same way.
    case never
    /// Worth another attempt later (capacity, a dropped connection).
    case transient
    /// Needs a change first: install, log in, change the config.
    case afterFix
}

public struct AgentFailure: Error, Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case missingExecutable, authOrConfig, unsupportedCapability, capacity, protocolError, process
        case timeout, cancellation, interrupted
        /// The provider's own dollar limit ended the work (Claude `--max-budget-usd`).
        case budgetExceeded
    }

    public var kind: Kind
    /// What to do about it, bounded.
    public var message: String
    public var retry: AgentRetry
    /// A path or log reference where the detail is kept.
    public var diagnostic: String?

    public init(_ kind: Kind, _ message: String, retry: AgentRetry, diagnostic: String? = nil) {
        self.kind = kind
        self.message = String(message.prefix(2048))
        self.retry = retry
        self.diagnostic = diagnostic
    }
}

public enum AgentAnswer: Sendable, Equatable {
    case text(String)
    /// An answer file the adapter had the provider write (Codex `-o`).
    case file(URL)
}

/// A tool call the policy refused, bounded: enough to offer a grant or explain the turn.
public struct AgentDenial: Sendable, Equatable {
    public var tool: String
    public var input: String?
    public var inputTruncated: Bool

    public init(tool: String, input: String? = nil, inputTruncated: Bool = false) {
        self.tool = tool
        self.input = input
        self.inputTruncated = inputTruncated
    }
}

/// How the process ended and what the provider said about the work, kept apart: exit 0 is not success.
public struct AgentCompletion: Sendable, Equatable {
    public enum ProviderOutcome: String, Sendable, Codable {
        case succeeded, failed
        /// The provider reported nothing usable (no result line, empty answer).
        case unknown
    }

    public var process: ProcessExit
    public var provider: ProviderOutcome
    public var answer: AgentAnswer?
    public var session: AgentSessionHandle?
    public var usage: AgentUsage?
    public var failure: AgentFailure?
    /// Activity lost to a slow consumer. The log of what happened is the child's output, not this stream.
    public var droppedActivity: Int
    public var outputTruncated: Bool
    /// Lines the process layer dropped for size. The decoder was told of each; this is for the record.
    public var oversizedLines: Int
    /// The calls the policy refused, at most the first 100, and how many there were in all.
    public var permissionDenials: [AgentDenial] = []
    public var permissionDenialCount: Int = 0
    /// Set when the recorder threw: the child was stopped and the rest of the output was not recorded.
    public var recordingFailure: String?

    /// What the agent said last, when the provider gave a text answer.
    public var summary: String? {
        if case .text(let text)? = answer { text } else { nil }
    }

    /// The only definition of "worked": the child ended on its own with status 0, the provider said it
    /// succeeded, nothing failed, and everything it printed was recorded. Whether the answer is a usable *result* is the stage's validator.
    public var succeeded: Bool {
        guard failure == nil, recordingFailure == nil, provider == .succeeded, process.cause == .natural else {
            return false
        }
        if case .exited(0) = process.termination { return true }
        return false
    }
}
