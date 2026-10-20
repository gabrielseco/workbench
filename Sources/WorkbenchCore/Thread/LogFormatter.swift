import Foundation

/// One-line descriptions of events, for `workbench log` and the live output of `workbench run`.
public enum LogFormatter {
    public static func describe(_ event: Event) -> String {
        let head = "\(String(format: "%4d", event.seq))  \(shortTime(event.ts))  t\(event.turn)  "
        switch event.kind {
        case .claude:
            return head + (describeClaude(event.data) ?? "claude")
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
        case .verifyStarted:
            return head + "verify started: \(event.data["command"]?.stringValue ?? "?")"
        case .verifyEnded:
            var out = head + "verify \(event.data["result"]?.stringValue?.replacingOccurrences(of: "_", with: " ") ?? "?")"
            if let ms = event.data["duration_ms"]?.intValue { out += "  \(ms / 1000)s" }
            if let n = event.data["proof_files"]?.intValue { out += "  \(n) proof file(s)" }
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
        case .worktreeRemoved, .branchRemoved, .branchAhead:
            return head + describeBranch(event)
        default:
            return head + event.kind.rawValue
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
        _ event: Event, sawStart: Bool, checks: Bool, turnSucceeded: Bool, verifiers: Bool = false,
        checkPassed: Bool = true
    ) -> Bool {
        let result = event.data["result"]?.stringValue
        let stopped = result == "stopped" || result == "interrupted"
        // The verifier follows a successful turn whose check passed (or that has none).
        let verifierFollows = verifiers && turnSucceeded
        switch event.kind {
        case .turnEnded: return sawStart && !(checks && !stopped) && !(verifierFollows && !checks)
        case .checkRan: return sawStart && !(verifierFollows && result == "passed")
        // Only an older log has a verify step.
        case .verifyEnded: return sawStart && !(verifierFollows && checkPassed)
        case .verifierEnded, .verifierSkipped: return sawStart
        // A setup that did not pass ends the run before any turn: nothing else will come.
        case .setupRan: return result != "passed"
        default: return false
        }
    }
}
