import Foundation

/// Reads `opencode run --format json`: one JSON object a line, `step_start`, `text`, `tool_use`, `step_finish` and `error`, each with
/// the `sessionID`. A turn is a success only when a `step_finish` with `reason: "stop"` was seen and the process ended on its own
/// with status 0: a stream that stops after a tool call (a kill, a crash, a lost line) is not one. Cost and tokens are summed over
/// the steps; OpenCode reports them per step. A refusal is not an event of its own: it is a `tool_use` whose `state.status` is
/// `error` and whose text says `Permission denied`.
struct OpencodeDecoder: AgentDecoder {
    var purpose: AgentSessionHandle.Purpose
    var maxRawBytes: Int
    static let maxRecordedDenials = 100
    static let maxDeniedInputCharacters = 4096

    private var session: AgentSessionHandle?
    private var lastText: String?
    private var usage = AgentUsage()
    private var sawUsage = false
    private var finishedWithStop = false
    private var lastError: (type: String, message: String)?
    private var denials: [AgentDenial] = []
    private var denialCount = 0

    init(purpose: AgentSessionHandle.Purpose, maxRawBytes: Int) {
        self.purpose = purpose
        self.maxRawBytes = maxRawBytes
    }

    mutating func consume(line: String) -> [AgentActivity] {
        guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return [.unknown(provider: .opencode, raw: String(line.prefix(maxRawBytes)))] }
        var out: [AgentActivity] = []
        if session == nil, let id = object["sessionID"] as? String, !id.isEmpty {
            let handle = AgentSessionHandle(provider: .opencode, purpose: purpose, value: id)
            session = handle
            out.append(.session(handle))
        }
        let part = object["part"] as? [String: Any] ?? [:]
        switch type {
        case "step_start":
            break
        case "text":
            guard let text = part["text"] as? String else { break }
            lastText = text
            out.append(.text(String(text.prefix(maxRawBytes))))
        case "tool_use":
            out += tool(part)
        case "step_finish":
            out += finish(part)
        case "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "an error"
            lastError = (error?["type"] as? String ?? "unknown", message)
            out.append(.diagnostic(String(message.prefix(maxRawBytes))))
        case "retry":
            // OpenCode retries a transient gateway error itself (a 503 was seen); the turn that follows is the one that counts.
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "an error"
            out.append(.diagnostic("retry \(object["attempt"] as? Int ?? 0): \(message.prefix(min(maxRawBytes, 300)))"))
        default:
            out.append(.unknown(provider: .opencode, raw: String(line.prefix(maxRawBytes))))
        }
        return out
    }

    private mutating func tool(_ part: [String: Any]) -> [AgentActivity] {
        let name = String((part["tool"] as? String ?? "tool").prefix(200))
        let state = part["state"] as? [String: Any] ?? [:]
        let input = state["input"] as? [String: Any]
        let detailKeys = ["command", "path", "filePath", "pattern", "url", "code"]
        let detail = detailKeys.lazy.compactMap { input?[$0] as? String }.first ?? ""
        guard state["status"] as? String == "error" else { return [.tool(name: name, summary: String(detail.prefix(300)))] }
        let reason = (state["error"] as? String) ?? (state["output"] as? String) ?? ""
        guard reason.contains("Permission denied") else {
            return [.diagnostic("\(name) failed: \(reason.prefix(300))")]
        }
        denialCount += 1
        if denials.count < Self.maxRecordedDenials {
            denials.append(
                AgentDenial(
                    tool: name, input: detail.isEmpty ? nil : String(detail.prefix(Self.maxDeniedInputCharacters)),
                    inputTruncated: detail.count > Self.maxDeniedInputCharacters))
        }
        return [.permissionDenied(tool: name, input: detail.isEmpty ? nil : String(detail.prefix(300)))]
    }

    private mutating func finish(_ part: [String: Any]) -> [AgentActivity] {
        let tokens = part["tokens"] as? [String: Any]
        let cache = tokens?["cache"] as? [String: Any]
        func add(_ old: Int?, _ new: Int?) -> Int? { new.map { (old ?? 0) + $0 } ?? old }
        usage.inputTokens = add(usage.inputTokens, tokens?["input"] as? Int)
        usage.outputTokens = add(usage.outputTokens, tokens?["output"] as? Int)
        usage.cachedInputTokens = add(usage.cachedInputTokens, cache?["read"] as? Int)
        if let cost = part["cost"] as? Double { usage.costUSD = (usage.costUSD ?? 0) + cost }
        sawUsage = true
        // A later step supersedes an earlier error: OpenCode retries, and the turn that ends in `stop` is the one that counts.
        finishedWithStop = part["reason"] as? String == "stop"
        if finishedWithStop { lastError = nil }
        return [.usage(usage)]
    }

    mutating func consume(oversizedPreview preview: String, totalBytes: Int) -> [AgentActivity] {
        // The lost line may have been the step that ends the turn; without it the turn is not a success.
        finishedWithStop = false
        return [.diagnostic("A line of \(totalBytes) bytes was over the limit; kept the first \(preview.utf8.count).")]
    }

    mutating func finish(exit: ProcessExit) -> AgentDecoderResult {
        let ended = exit.cause == .natural && exit.termination == .exited(0)
        let answer = lastText.map { AgentAnswer.text($0) }
        let counted = sawUsage ? usage : nil
        if finishedWithStop {
            return AgentDecoderResult(
                outcome: ended ? .succeeded : .failed, answer: answer, session: session, usage: counted,
                permissionDenials: denials, permissionDenialCount: denialCount)
        }
        guard let lastError else {
            return AgentDecoderResult(
                outcome: .unknown, answer: answer, session: session, usage: counted,
                failure: Self.startupFailure(exit.stderrTail), permissionDenials: denials, permissionDenialCount: denialCount)
        }
        return AgentDecoderResult(
            outcome: .failed, answer: answer, session: session, usage: counted,
            failure: Self.classify(type: lastError.type, message: lastError.message, maxBytes: maxRawBytes),
            permissionDenials: denials, permissionDenialCount: denialCount)
    }

    /// What a gateway or provider error means for the person: log in, wait, or change the config.
    static func classify(type: String, message: String, maxBytes: Int) -> AgentFailure {
        let text = message.lowercased()
        let shown = String(message.prefix(min(maxBytes, 1024)))
        if text.contains("credit balance") || text.contains("insufficient") || text.contains("exceededbudget")
            || text.contains("budget has been exceeded") {
            return AgentFailure(.budgetExceeded, "The gateway refused for lack of credit or budget: \(shown)", retry: .afterFix)
        }
        if text.contains("401") || text.contains("unauthorized") || text.contains("invalid api key")
            || text.contains("authentication") || type.contains("auth") {
            return AgentFailure(.authOrConfig, "The gateway refused the key: \(shown)", retry: .afterFix)
        }
        if text.contains("rate limit") || text.contains("429") || text.contains("overloaded") || text.contains("capacity")
            || text.contains("timed out") || text.contains("connection") {
            return AgentFailure(.capacity, "The gateway or its model is busy or unreachable: \(shown)", retry: .transient)
        }
        return AgentFailure(.process, shown, retry: .never)
    }

    /// A process that ended with no step at all: it never started (a bad config, a sandbox that stopped its server), and says so on
    /// stderr, if anywhere.
    static func startupFailure(_ stderrTail: String) -> AgentFailure? {
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        return AgentFailure(.process, "OpenCode ended without finishing a step: \(tail.suffix(600))", retry: .afterFix)
    }
}
