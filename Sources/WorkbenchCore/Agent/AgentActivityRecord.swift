import Foundation

/// How a normalized `AgentActivity` is stored in the log as an `agent.activity` event (docs/spec/event-log.md).
/// Bounded here, so a provider cannot make one event large; what the provider did not report is left out.
public enum AgentActivityRecord {
    /// Characters kept of any text field; `truncated` is set when one was cut.
    public static let maxTextCharacters = 4096
    /// Persisted activity events per turn. The rest are counted in one `dropped` event.
    public static let maxPerTurn = 1000
    /// Past the cap, a `dropped` record at most this often (seconds) while the turn goes on, so it does not read as stuck.
    public static let dropMarkInterval: TimeInterval = 30

    /// The event's `data`, or nil for activity the log does not keep (`started`: `turn.started` has the pid).
    public static func data(for activity: AgentActivity, provider: String) -> JSONValue? {
        var out: [String: JSONValue] = ["provider": .string(provider)]
        var truncated = false
        func bounded(_ text: String) -> JSONValue {
            if text.count > maxTextCharacters { truncated = true }
            return .string(String(text.prefix(maxTextCharacters)))
        }
        switch activity {
        case .started:
            return nil
        case .text(let text):
            out["type"] = "text"
            out["text"] = bounded(text)
        case .tool(let name, let summary):
            out["type"] = "tool"
            out["name"] = bounded(name)
            out["summary"] = bounded(summary)
        case .permissionDenied(let tool):
            out["type"] = "permission_denied"
            out["tool"] = bounded(tool)
        case .usage(let usage):
            out["type"] = "usage"
            if let n = usage.inputTokens { out["input_tokens"] = .int(n) }
            if let n = usage.outputTokens { out["output_tokens"] = .int(n) }
            if let n = usage.cachedInputTokens { out["cached_input_tokens"] = .int(n) }
            if let cost = usage.costUSD { out["cost_usd"] = .double(cost) }
        case .session(let handle):
            out["type"] = "session"
            out["value"] = bounded(handle.value)
            out["purpose"] = .string(handle.purpose.rawValue)
        case .diagnostic(let text):
            out["type"] = "diagnostic"
            out["text"] = bounded(text)
        case .unknown(let rawProvider, let raw):
            out["type"] = "unknown"
            out["provider"] = .string(rawProvider.rawValue)
            out["raw"] = bounded(raw)
            if truncated { out["raw_truncated"] = true }
            return .object(out)
        case .dropped(let count):
            out["type"] = "dropped"
            out["count"] = .int(count)
        }
        if truncated { out["truncated"] = true }
        return .object(out)
    }

    /// The `dropped` record for the activity past `maxPerTurn`. It still counts the tool calls and refusals among the
    /// items it stands for, so a long turn's totals stay known.
    public static func droppedData(count: Int, provider: String, toolCalls: Int = 0, denied: Int = 0) -> JSONValue {
        .object([
            "provider": .string(provider), "type": "dropped", "count": .int(count), "reason": "cap",
            "tool_calls": .int(toolCalls), "denied": .int(denied),
        ])
    }
}
