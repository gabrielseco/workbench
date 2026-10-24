import Foundation

/// One-line descriptions of events, for `workbench log` and the live output of `workbench run`.
public enum LogFormatter {
    /// A `log` line for an entry: an event as `describe(_ event:)` has it, a transcript line the same way with
    /// its `seq` (a dash when the line is not in `events.jsonl`).
    public static func describe(_ entry: LogEntry) -> String {
        switch entry {
        case .event(let event):
            return describe(event)
        case .transcript(let line):
            let seq = line.seq.map { String(format: "%4d", $0) } ?? "   -"
            return "\(seq)  \(shortTime(line.ts))  t\(line.turn)  " + (describeClaude(line.data) ?? "claude")
        case .unreadableTranscript(let turn, let reason):
            return "   -  --:--:--  t\(turn)  transcript cannot be read: \(reason)"
        }
    }

    public static func describe(_ event: Event) -> String {
        let head = "\(String(format: "%4d", event.seq))  \(shortTime(event.ts))  t\(event.turn)  "
        switch event.kind {
        case .claude, .agentActivity:
            return head + describeStream(event)
        case .turnStarted:
            let resume = event.data["resume"] == true ? "resume" : "new session"
            let pid = event.data["pid"]?.intValue.map { " pid \($0)" } ?? ""
            return head + "turn started (\(resume)\(pid))"
        case .turnEnded:
            var out = head + "turn ended: \(event.data["result"]?.stringValue ?? "?")"
            if let cost = costText(event.data["cost_usd"]) { out += "  \(cost)" }
            if let ms = event.data["duration_ms"]?.intValue { out += "  \(ms / 1000)s" }
            if let denials = event.data["permission_denials"]?.intValue, denials > 0 {
                out += "  \(denials) denied"
            }
            return out
        case .checkStarted:
            return head + "check started: \(event.data["command"]?.stringValue ?? "?")"
        case .checkRan:
            var out = head + describeCheck(
                result: event.data["result"]?.stringValue ?? "?", exitCode: event.data["exit_code"]?.intValue,
                signal: event.data["signal"]?.intValue)
            if let ms = event.data["duration_ms"]?.intValue { out += "  \(ms / 1000)s" }
            if event.data["output_truncated"] == true { out += "  output truncated" }
            return out
        case .verifierStarted:
            return head + "verifier started: \(event.data["skill"]?.stringValue ?? "?")"
        case .runStarted:
            return head + "app starting: \(event.data["command"]?.stringValue ?? "?")"
        case .runEnded:
            var out = head + (event.data["ready"] == true ? "app stopped" : "app did not come up")
            if let reason = event.data["reason"]?.stringValue { out += " (\(reason))" }
            return out
        case .verifierSkipped:
            return head + "verifier skipped: \(event.data["reason"]?.stringValue ?? "?")"
        case .verifierEnded:
            var out = head + (event.data["ok"] == true ? "verifier finished" : "verifier did not finish")
            if let reason = event.data["reason"]?.stringValue { out += " (\(reason))" }
            if let ms = event.data["duration_ms"]?.intValue { out += "  \(ms / 1000)s" }
            if case .array(let files)? = event.data["files"] { out += "  \(files.count) proof file(s)" }
            return out
        case .proofAdded:
            return head + "proof: \(event.data["path"]?.stringValue ?? "?")"
        case .setupRan:
            var out = head + "setup \(event.data["result"]?.stringValue?.replacingOccurrences(of: "_", with: " ") ?? "?")"
            if let ms = event.data["duration_ms"]?.intValue { out += "  \(ms / 1000)s" }
            return out
        case .threadNote:
            return head + "feedback: \(event.data["text"]?.stringValue ?? "")"
        case .grantAdded:
            let scope = ThreadState.safeLine(event.data["scope"]?.stringValue ?? "?", limit: 20)
            return head + "grant (\(scope)): " + ThreadState.safeLine(event.data["pattern"]?.stringValue ?? "?", limit: 300)
        case .reviewDecision:
            return head + "decision: \(event.data["decision"]?.stringValue ?? "?")"
        case .agentAttemptStarted, .agentAttemptEnded, .goalDraftStarted, .goalDraftFinished, .goalApproved:
            return head + describeAgent(event)
        case .worktreeRemoved, .branchRemoved, .branchAhead:
            return head + describeBranch(event)
        default:
            return head + event.kind.rawValue
        }
    }

    /// An attempt of a provider process, or a goal draft: one line, the provider and model first.
    static func describeAgent(_ event: Event) -> String {
        if event.kind == .goalApproved, event.data["provider"] == nil { return event.kind.rawValue }
        let id = ThreadState.safeLine(event.data["attempt"]?.stringValue ?? "", limit: 20)
        let provider = ThreadState.safeLine(event.data["provider"]?.stringValue ?? "?", limit: 20)
        let model = event.data["model"]?.stringValue.map { ThreadState.safeLine($0, limit: 60) } ?? "default model"
        let role = ThreadState.safeLine(event.data["role"]?.stringValue ?? "", limit: 20)
        switch event.kind {
        case .goalApproved:
            return "goal approved for coding on \(provider), \(model)"
        case .agentAttemptStarted:
            let stage = event.data["stage"]?.stringValue.map { " \(ThreadState.safeLine($0, limit: 40))" } ?? ""
            let round = event.data["round"]?.intValue.map { " round \($0)" } ?? ""
            let spawned = event.data["spawned"] == false ? ", nothing started" : ""
            return "attempt \(id): \(role)\(stage)\(round) on \(provider), \(model)\(spawned)"
        case .agentAttemptEnded:
            var out = "attempt \(id) ended: \(event.data["outcome"]?.stringValue ?? "?")"
            if let reason = event.data["reason"]?.stringValue { out += " (\(ThreadState.safeLine(reason, limit: 100)))" }
            if event.data["synthetic"] == true { out += " (recovered)" }
            return out
        case .goalDraftStarted:
            return "goal draft started on \(provider), \(model)"
        default:
            var out = "goal draft " + (event.data["ok"] == true ? "finished" : "did not finish")
            if let reason = event.data["reason"]?.stringValue { out += " (\(ThreadState.safeLine(reason, limit: 100)))" }
            return out
        }
    }

    /// What happened to the thread's worktree or branch around `ship` and `clean`.
    static func describeBranch(_ event: Event) -> String {
        let sha = event.data["head_sha"]?.stringValue.map { " at \($0.prefix(12))" } ?? ""
        switch event.kind {
        case .worktreeRemoved:
            return "worktree removed (\(event.data["reason"]?.stringValue ?? "?"))\(sha); the branch is kept"
        case .branchRemoved:
            return "branch removed (pull request \(event.data["reason"]?.stringValue ?? "?"))\(sha)"
        default:
            return BranchAhead.describe(event.data)
        }
    }

    /// `check passed`, `check failed (exit 1)`, `check timed out`: how a check ended, in words.
    public static func describeCheck(result: String, exitCode: Int?, signal: Int?) -> String {
        var out = "check \(result.replacingOccurrences(of: "_", with: " "))"
        if result == CheckResult.failed.rawValue {
            if let exitCode { out += " (exit \(exitCode))" } else if let signal { out += " (signal \(signal))" }
        }
        return out
    }

    private static func describeStream(_ event: Event) -> String {
        if event.kind == .agentActivity { return describeActivity(event.data) }
        return describeClaude(event.data) ?? "claude"
    }

    /// One line for a normalized `agent.activity`; the text is the provider's, so it is made safe to print.
    public static func describeActivity(_ data: JSONValue) -> String {
        func safe(_ key: String, _ limit: Int = 100) -> String {
            ThreadState.safeLine(data[key]?.stringValue ?? "", limit: limit)
        }
        let provider = ThreadState.safeLine(data["provider"]?.stringValue ?? "?", limit: 30)
        switch data["type"]?.stringValue {
        case "text": return "\(provider): \(safe("text"))"
        case "tool": return "tool: \(safe("name", 40)) \(safe("summary", 60))"
        case "permission_denied": return "tool denied: \(safe("tool", 60))"
        case "usage":
            var parts: [String] = []
            if let n = data["input_tokens"]?.intValue { parts.append("\(n) in") }
            if let n = data["output_tokens"]?.intValue { parts.append("\(n) out") }
            if let cost = costText(data["cost_usd"]) { parts.append(cost) }
            return "usage: " + (parts.isEmpty ? "not reported" : parts.joined(separator: ", "))
        case "session": return "\(provider) session \(safe("purpose", 20))"
        case "diagnostic": return "\(provider) note: \(safe("text"))"
        case "unknown": return "\(provider) event not understood: \(safe("raw", 80))"
        case "dropped": return "\(data["count"]?.intValue ?? 0) activity item(s) not recorded"
        default: return "\(provider) activity"
        }
    }

    /// The interesting part of a raw `claude` stream line, or nil for noise (partial messages, hooks).
    public static func describeClaude(_ data: JSONValue) -> String? {
        if data["truncated"] == true {
            return "(line too long: \(data["original_bytes"]?.intValue ?? 0) bytes, cut)"
        }
        if let raw = data["invalid_json"]?.stringValue { return "(not JSON) \(raw.prefix(80))" }
        guard let type = data["type"]?.stringValue else { return nil }
        switch type {
        case "system":
            return data["subtype"]?.stringValue == "init" ? "session started" : nil
        case "assistant":
            guard case .array(let blocks)? = data["message"]?["content"] else { return nil }
            var parts: [String] = []
            for block in blocks {
                switch block["type"]?.stringValue {
                case "text": if let t = block["text"]?.stringValue { parts.append("claude: \(oneLine(t))") }
                case "tool_use":
                    let name = block["name"]?.stringValue ?? "tool"
                    let input = block["input"]
                    let detail = input?["command"]?.stringValue ?? input?["file_path"]?.stringValue
                        ?? input?["pattern"]?.stringValue ?? ""
                    parts.append("tool: \(name) \(oneLine(detail))")
                default: break
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: " | ")
        case "user":
            guard case .array(let blocks)? = data["message"]?["content"] else { return nil }
            for block in blocks where block["type"]?.stringValue == "tool_result" {
                if block["is_error"] == true { return "tool result: error" }
            }
            return nil
        case "result":
            let subtype = data["subtype"]?.stringValue ?? "?"
            return "result: \(subtype)"
        default:
            return nil
        }
    }

    private static func shortTime(_ ts: String) -> String {
        // 2026-10-12T20:11:03.120Z -> 20:11:03
        guard let t = ts.firstIndex(of: "T") else { return ts }
        return String(ts[ts.index(after: t)...].prefix(8))
    }

    private static func costText(_ value: JSONValue?) -> String? {
        switch value {
        case .double(let d)?: String(format: "$%.4f", d)
        case .int(let i)?: "$\(i)"
        default: nil
        }
    }

    private static func oneLine(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 100 ? String(flat.prefix(100)) + "..." : flat
    }

    /// Whether the newest turn in the log ended `succeeded`; where `log -f` starts when it joins a run midway.
    public static func latestTurnSucceeded(_ events: [Event]) -> Bool {
        events.last { $0.kind == .turnEnded }?.data["result"]?.stringValue == "succeeded"
    }

    /// Whether `log -f` has seen everything this run will write. A turn is followed to the end of its check,
    /// then, when it succeeded and a verifier will run, to the end of that.
    public static func followEnds(
        _ event: Event, sawStart: Bool, checks: Bool, turnSucceeded: Bool, verifiers: Bool = false
    ) -> Bool {
        let result = event.data["result"]?.stringValue
        let stopped = result == "stopped" || result == "interrupted"
        // The verifier follows a successful turn whose check passed (or that has none).
        let verifierFollows = verifiers && turnSucceeded
        switch event.kind {
        case .turnEnded: return sawStart && !(checks && !stopped) && !(verifierFollows && !checks)
        case .checkRan: return sawStart && !(verifierFollows && result == "passed")
        case .verifierEnded, .verifierSkipped: return sawStart
        // A setup that did not pass ends the run before any turn: nothing else will come.
        case .setupRan: return result != "passed"
        default: return false
        }
    }
}
