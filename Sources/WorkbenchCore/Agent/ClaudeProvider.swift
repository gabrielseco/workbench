import Foundation

/// The Claude Code adapter. Coding turns build their argv with `Config.invocation` (flags verified in the P1
/// spikes and P9 task 1) and decode `stream-json`; this type is the seam between that and `AgentRequest`, plus
/// the judgement of how a turn ended, which used to live in `ThreadRunner`. A `readOnlyEvidence` request is a
/// one-shot `--output-format json` call that `--restricted` confines to its working directory.
public struct ClaudeProvider: AgentProvider {
    public var config: Config

    public init(config: Config) { self.config = config }

    public var id: AgentProviderID { .claude }

    public var capabilities: AgentCapabilities {
        AgentCapabilities(
            policies: [.scopedCoding, .readOnlyEvidence], resume: .callerSuppliedID, streamsActivity: true,
            imageAttachments: false, structuredOutput: true, reportsUsage: true, hardDollarCap: true, confinesReads: true)
    }

    public func invocation(for request: AgentRequest) throws -> AgentInvocation {
        func refuse(_ why: String) -> AgentFailure { AgentFailure(.unsupportedCapability, why, retry: .afterFix) }
        if request.policy == .readOnlyEvidence { return try readOnlyInvocation(for: request) }
        // A timeout-only coding turn runs without `--max-budget-usd`; its cost is still read from the result line.
        let budget: Decimal?
        if case .hardCap(let cap) = request.spend { budget = cap } else { budget = nil }
        let sessionID: UUID
        let resume: Bool
        switch request.session {
        case .start(let proposed):
            guard let proposed, let uuid = UUID(uuidString: proposed) else {
                throw refuse("Claude needs a session id chosen up front (a UUID) to start a conversation.")
            }
            (sessionID, resume) = (uuid, false)
        case .resume(let handle):
            guard let uuid = UUID(uuidString: handle.value) else {
                throw refuse("The session handle is not a Claude session id.")
            }
            (sessionID, resume) = (uuid, true)
        case .none:
            throw refuse("Claude coding turns keep a conversation; a one-shot request is for evaluations.")
        }

        let turn = TurnRequest(
            sessionID: sessionID, resume: resume, budgetUSD: budget, prompt: request.prompt,
            appendSystemPrompt: request.rules, model: request.model, extraAllowed: request.grants,
            reasoningEffort: request.reasoningEffort)
        let built: ClaudeInvocation
        do { built = try config.invocation(for: turn) } catch {
            throw refuse("The Claude command line could not be built: \(error)")
        }

        // The prompt and the rules are in the thread's files, not in a log line.
        var shown = built.arguments
        if let dashes = shown.firstIndex(of: "--") { shown = Array(shown[..<dashes]) }
        if let i = shown.firstIndex(of: "--append-system-prompt"), i + 1 < shown.count { shown[i + 1] = "<rules>" }
        return AgentInvocation(
            executable: built.executable, arguments: built.arguments,
            environment: config.childEnvironment(from: request.environment), displayArguments: shown)
    }

    /// A judge or reviewer: no repository writes and no posting. With evidence files it gets `Read` and, under
    /// `--restricted`, can read only the folder it runs in; with none it has no tools. Its own session and budget.
    private func readOnlyInvocation(for request: AgentRequest) throws -> AgentInvocation {
        func refuse(_ why: String) -> AgentFailure { AgentFailure(.unsupportedCapability, why, retry: .afterFix) }
        guard case .hardCap(let budget) = request.spend else {
            throw refuse("A read-only Claude call runs with a dollar cap; timeout-only spending is not available yet.")
        }
        guard request.grants.isEmpty else { throw refuse("A read-only call takes no extra permissions.") }
        // The id is the caller's, so the argv it logs is the argv that runs.
        let sessionID: UUID
        switch request.session {
        case .start(let proposed):
            guard let proposed, let uuid = UUID(uuidString: proposed) else {
                throw refuse("Claude needs a session id chosen up front (a UUID) to start a conversation.")
            }
            sessionID = uuid
        case .none:
            throw refuse("A read-only Claude call needs a fresh session id chosen up front.")
        case .resume:
            throw refuse("A read-only call is independent of every earlier conversation and is never resumed.")
        }
        var args = [
            "-p", "--output-format", "json", "--permission-prompts", "none", "--restricted",
            "--session-id", sessionID.uuidString.lowercased(),
            "--max-budget-usd", NSDecimalNumber(decimal: budget).stringValue,
        ]
        if config.safeMode { args += ["--safe-mode", "--disable-slash-commands"] }
        if let model = request.model { args += ["--model", model] }
        if let effort = request.reasoningEffort { args += ["--effort", effort] }
        args += request.evidenceFiles.isEmpty ? ["--tools", ""] : ["--tools", "Read", "--allowedTools", "Read"]
        args += ["--", request.prompt]
        return AgentInvocation(
            executable: config.claudePath, arguments: args, environment: config.childEnvironment(from: request.environment),
            displayArguments: PRDescriber.displayArguments(args))
    }

    public func makeDecoder(for request: AgentRequest) -> any AgentDecoder {
        if request.policy == .readOnlyEvidence { return ClaudeEnvelopeDecoder(maxRawBytes: request.limits.maxRawBytes) }
        var sessionID: String?
        switch request.session {
        case .start(let proposed): sessionID = proposed
        case .resume(let handle): sessionID = handle.value
        case .none: break
        }
        return ClaudeDecoder(
            sessionID: sessionID?.lowercased(), purpose: request.purpose, maxRawBytes: request.limits.maxRawBytes)
    }
}

/// Reads Claude's `stream-json`. One `result` line ends a turn; everything else is activity or ignored.
struct ClaudeDecoder: AgentDecoder {
    static let maxRecordedDenials = 100
    /// Tool ids remembered for naming a refusal; past this the table starts over rather than grow.
    private static let maxRememberedTools = 512
    static let maxDeniedInputCharacters = 4096
    private static let deniedInputKeys = ["command", "file_path", "path", "notebook_path", "url", "pattern", "query"]

    /// Event types the adapter knows. `stream_event` (partial messages) and the rest are deliberately not activity.
    private static let knownTypes: Set<String> = [
        "system", "stream_event", "assistant", "user", "result", "rate_limit_event",
    ]

    var sessionID: String?
    var purpose: AgentSessionHandle.Purpose
    var maxRawBytes: Int
    /// The last `result` line that parsed, kept as text so the decoder stays `Sendable`.
    private var resultText: String?
    private var session: AgentSessionHandle?
    /// `tool_use` ids to tool names, so a refusal in a later `user` line can say which tool was refused.
    private var toolNames: [String: String] = [:]
    /// The one fixed sentence the permission layer gives the model when it refuses a call.
    private static let denialText = "Permission for this tool use was denied"

    init(sessionID: String?, purpose: AgentSessionHandle.Purpose, maxRawBytes: Int) {
        self.sessionID = sessionID
        self.purpose = purpose
        self.maxRawBytes = maxRawBytes
    }

    mutating func consume(line: String) -> [AgentActivity] {
        var items: [AgentActivity] = []
        // The session is confirmed by the first line that names it: a resume of an id Claude never saw fails
        // at once with no output, and that is how the runner tells the two apart.
        if session == nil, let sessionID, line.contains("\"session_id\":\"\(sessionID)\"") {
            let handle = AgentSessionHandle(provider: .claude, purpose: purpose, value: sessionID)
            session = handle
            items.append(.session(handle))
        }
        if line.contains("\"type\":\"result\""), Self.object(line) != nil {
            resultText = line
        } else if line.contains("\"type\":\"assistant\""), let parsed = Self.object(line) {
            items += activity(fromAssistant: parsed)
        } else if line.contains("\"type\":\"user\""), line.contains(Self.denialText), let parsed = Self.object(line) {
            items += denials(inUser: parsed)
        } else if !Self.knownTypes.contains(Self.eventType(of: line) ?? "") {
            // Not a line this adapter understands: kept, bounded, so a diagnostic from a newer Claude is not lost.
            items.append(.unknown(provider: .claude, raw: String(line.prefix(maxRawBytes))))
        }
        return items
    }

    mutating func consume(oversizedPreview preview: String, totalBytes: Int) -> [AgentActivity] { [] }

    mutating func finish(exit: ProcessExit) -> AgentDecoderResult {
        // Past the output limit the result line may have been dropped from the stream; it is kept aside.
        var late: String?
        var resultLine = resultText.flatMap(Self.object)
        if resultLine == nil, let last = exit.lastLineAfterLimit {
            late = last
            if let parsed = Self.object(last), parsed["type"] as? String == "result" { resultLine = parsed }
        }
        let (outcome, failure) = Self.judge(exit: exit, result: resultLine)

        var usage: AgentUsage?
        if let cost = resultLine?["total_cost_usd"] as? NSNumber {
            usage = AgentUsage(costUSD: cost.doubleValue)
        }
        let (denials, count) = Self.denials(resultLine)
        let summary = (resultLine?["result"] as? String).map { AgentAnswer.text($0) }
        return AgentDecoderResult(
            outcome: outcome, answer: summary, session: session, usage: usage, failure: failure,
            permissionDenials: denials, permissionDenialCount: count, lateLine: late)
    }

    // MARK: How a turn ended (pure, tested directly)

    /// Stop and deadline are decided by the runner (they outrank anything Claude printed). Past those: a signal
    /// or no `result` line is a failure, a spent dollar limit is `budgetExceeded`, a success line from a process
    /// that then exited non-zero is not a success, and only `subtype: success` without `is_error` is.
    static func judge(exit: ProcessExit, result: [String: Any]?) -> (AgentCompletion.ProviderOutcome, AgentFailure?) {
        if exit.cause != .natural { return (.failed, nil) }
        if case .signaled = exit.termination { return (.failed, nil) }
        guard let result else { return (.failed, nil) }

        let subtype = result["subtype"] as? String
        let terminal = result["terminal_reason"] as? String
        if subtype == "error_max_budget_usd" || terminal == "budget_exhausted" {
            return (.failed, AgentFailure(.budgetExceeded, "Claude's dollar limit for the turn was reached.", retry: .never))
        }
        if case .exited(let code) = exit.termination, code != 0 { return (.failed, nil) }
        if subtype == "success", result["is_error"] as? Bool != true { return (.succeeded, nil) }
        return (.failed, nil)
    }

    /// The turn's denied calls from the parsed `result` line, so the full command survives a result line the log
    /// had to cut for size. Raw text, bounded; whoever prints it makes it safe.
    static func denials(_ result: [String: Any]?) -> ([AgentDenial], Int) {
        guard let all = result?["permission_denials"] as? [Any], !all.isEmpty else { return ([], 0) }
        var calls: [AgentDenial] = []
        for case let denial as [String: Any] in all.prefix(maxRecordedDenials) {
            guard let tool = denial["tool_name"] as? String else { continue }
            var call = AgentDenial(tool: String(tool.prefix(200)))
            let input = denial["tool_input"] as? [String: Any]
            if let text = deniedInputKeys.lazy.compactMap({ input?[$0] as? String }).first(where: { !$0.isEmpty }) {
                call.input = String(text.prefix(maxDeniedInputCharacters))
                call.inputTruncated = text.count > maxDeniedInputCharacters
            }
            calls.append(call)
        }
        return (calls, all.count)
    }

    private mutating func activity(fromAssistant message: [String: Any]) -> [AgentActivity] {
        guard let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        var items: [AgentActivity] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { items.append(.text(String(text.prefix(maxRawBytes)))) }
            case "tool_use":
                if let name = block["name"] as? String {
                    if let id = block["id"] as? String {
                        if toolNames.count >= Self.maxRememberedTools { toolNames.removeAll() }
                        toolNames[id] = String(name.prefix(200))
                    }
                    let input = block["input"] as? [String: Any]
                    let summary = Self.deniedInputKeys.lazy.compactMap { input?[$0] as? String }.first ?? ""
                    items.append(.tool(name: String(name.prefix(200)), summary: String(summary.prefix(200))))
                }
            default: break
            }
        }
        return items
    }

    /// A refused call is a `tool_result` flagged as an error that carries the permission layer's sentence; a command
    /// that merely failed is not one.
    private func denials(inUser message: [String: Any]) -> [AgentActivity] {
        guard let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            guard block["type"] as? String == "tool_result", block["is_error"] as? Bool == true,
                (block["content"] as? String)?.hasPrefix(Self.denialText) == true
            else { return nil }
            let name = (block["tool_use_id"] as? String).flatMap { toolNames[$0] }
            return .permissionDenied(tool: name ?? "tool")
        }
    }

    /// The `type` of a stream line. Claude writes it first, so the common case is a prefix read, not a parse.
    static func eventType(of line: String) -> String? {
        let lead = #"{"type":""#
        if line.hasPrefix(lead) {
            let rest = line.dropFirst(lead.count)
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        return object(line)?["type"] as? String
    }

    private static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

/// What `claude -p --output-format json` prints: one object whose `result` is the model's answer.
struct ClaudeEnvelope: Equatable {
    var answer: String?
    var isError: Bool
    var budgetExhausted: Bool
    var costUSD: Double?

    /// nil when `output` holds no JSON object at all.
    static func decode(_ output: String) -> ClaudeEnvelope? {
        guard let outer = PRDescriber.object(from: output) else { return nil }
        return ClaudeEnvelope(
            answer: outer["result"] as? String, isError: outer["is_error"] as? Bool == true,
            budgetExhausted: outer["subtype"] as? String == "error_max_budget_usd"
                || outer["terminal_reason"] as? String == "budget_exhausted",
            costUSD: (outer["total_cost_usd"] as? NSNumber)?.doubleValue)
    }
}

/// Reads the single-object output of a read-only call. It unwraps the envelope and nothing more: whether the
/// answer is a usable verdict is the stage's validator.
struct ClaudeEnvelopeDecoder: AgentDecoder {
    var maxRawBytes: Int
    private var lines: [String] = []
    private var lostLine = false

    init(maxRawBytes: Int) { self.maxRawBytes = maxRawBytes }

    mutating func consume(line: String) -> [AgentActivity] {
        lines.append(line)
        return []
    }

    /// The one object is the answer, so losing a line of it leaves nothing to read.
    mutating func consume(oversizedPreview preview: String, totalBytes: Int) -> [AgentActivity] {
        lostLine = true
        return []
    }

    mutating func finish(exit: ProcessExit) -> AgentDecoderResult {
        let output = lines.joined(separator: "\n")
        guard !lostLine, let envelope = ClaudeEnvelope.decode(output) else {
            let why = lostLine ? "its answer was over the line limit" : "its output was not a JSON object"
            return AgentDecoderResult(
                outcome: .unknown,
                failure: AgentFailure(.protocolError, "claude's answer was not usable: \(why)", retry: .never))
        }
        let usage = envelope.costUSD.map { AgentUsage(costUSD: $0) }
        if envelope.budgetExhausted {
            return AgentDecoderResult(
                outcome: .failed, usage: usage,
                failure: AgentFailure(.budgetExceeded, "Claude's dollar limit for the call was reached.", retry: .never))
        }
        if envelope.isError {
            return AgentDecoderResult(
                outcome: .failed, usage: usage,
                failure: AgentFailure(.protocolError, "claude reported an error", retry: .never))
        }
        guard let answer = envelope.answer else {
            return AgentDecoderResult(
                outcome: .unknown, usage: usage,
                failure: AgentFailure(.protocolError, "claude's answer was not usable: no result", retry: .never))
        }
        return AgentDecoderResult(outcome: .succeeded, answer: .text(answer), usage: usage)
    }
}
