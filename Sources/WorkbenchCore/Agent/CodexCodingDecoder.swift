import Foundation

/// Reads a Codex coding turn's `--json` stream: its session, what it said and ran, its token counts, and whether the
/// turn completed. Cost is never reported by Codex and stays unknown. A turn is a success only when `turn.completed`
/// was seen and the process ended on its own with status 0; a stream that stops short of it is not one.
struct CodexCodingDecoder: AgentDecoder {
    var purpose: AgentSessionHandle.Purpose
    var maxRawBytes: Int
    private var session: AgentSessionHandle?
    private var lastMessage: String?
    private var usage: AgentUsage?
    private var completed = false
    private var failureMessage: String?
    private var sawCapacity = false

    init(purpose: AgentSessionHandle.Purpose, maxRawBytes: Int) {
        self.purpose = purpose
        self.maxRawBytes = maxRawBytes
    }

    mutating func consume(line: String) -> [AgentActivity] {
        if CodexDecoder.atCapacity(line) { sawCapacity = true }
        guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return [.unknown(provider: .codex, raw: String(line.prefix(maxRawBytes)))] }
        switch type {
        case "thread.started":
            guard let id = object["thread_id"] as? String, session == nil else { return [] }
            let handle = AgentSessionHandle(provider: .codex, purpose: purpose, value: id)
            session = handle
            return [.session(handle)]
        case "turn.started":
            return []
        case "item.started", "item.completed":
            return item(object, finished: type == "item.completed", raw: line)
        case "turn.completed":
            completed = true
            let counts = object["usage"] as? [String: Any]
            usage = AgentUsage(
                inputTokens: counts?["input_tokens"] as? Int, outputTokens: counts?["output_tokens"] as? Int,
                cachedInputTokens: counts?["cached_input_tokens"] as? Int, costUSD: nil)
            return usage.map { [.usage($0)] } ?? []
        case "turn.failed":
            failureMessage = (object["error"] as? [String: Any])?["message"] as? String ?? "the turn failed"
            return [.diagnostic(String((failureMessage ?? "").prefix(maxRawBytes)))]
        case "error":
            // Codex reports reconnects this way too, so it only explains the end if the turn never completed.
            let message = object["message"] as? String ?? "an error"
            failureMessage = failureMessage ?? message
            return [.diagnostic(String(message.prefix(maxRawBytes)))]
        default:
            return [.unknown(provider: .codex, raw: String(line.prefix(maxRawBytes)))]
        }
    }

    private mutating func item(_ object: [String: Any], finished: Bool, raw: String) -> [AgentActivity] {
        guard let item = object["item"] as? [String: Any], let kind = item["type"] as? String else {
            return [.unknown(provider: .codex, raw: String(raw.prefix(maxRawBytes)))]
        }
        switch kind {
        case "agent_message":
            guard finished, let text = item["text"] as? String else { return [] }
            lastMessage = text
            return [.text(String(text.prefix(maxRawBytes)))]
        case "command_execution":
            let command = String((item["command"] as? String ?? "").prefix(300))
            if !finished { return [.tool(name: "shell", summary: command)] }
            guard let code = item["exit_code"] as? Int, code != 0 else { return [] }
            return [.diagnostic("a command exited with status \(code): \(command)")]
        case "file_change":
            return finished ? [] : [.tool(name: "edit", summary: "file change")]
        case "reasoning":
            return []
        default:
            return [.unknown(provider: .codex, raw: String(raw.prefix(maxRawBytes)))]
        }
    }

    mutating func consume(oversizedPreview preview: String, totalBytes: Int) -> [AgentActivity] {
        // A lost line may have been the one that ends the turn; without `turn.completed` the turn is not a success.
        [.diagnostic("A line of \(totalBytes) bytes was over the limit; kept the first \(preview.utf8.count).")]
    }

    mutating func finish(exit: ProcessExit) -> AgentDecoderResult {
        var ended = false
        if exit.cause == .natural, case .exited(0) = exit.termination { ended = true }
        let answer = lastMessage.map { AgentAnswer.text($0) }
        if !completed, sawCapacity || CodexDecoder.atCapacity(exit.stderrTail) {
            return AgentDecoderResult(
                outcome: .failed, session: session,
                failure: AgentFailure(.capacity, "Codex's model is at capacity.", retry: .transient))
        }
        if completed {
            return AgentDecoderResult(
                outcome: ended ? .succeeded : .failed, answer: answer, session: session, usage: usage)
        }
        guard let failureMessage else {
            return AgentDecoderResult(outcome: .unknown, answer: answer, session: session, usage: usage)
        }
        return AgentDecoderResult(
            outcome: .failed, answer: answer, session: session, usage: usage,
            failure: AgentFailure(.process, String(failureMessage.prefix(1024)), retry: .never))
    }
}
