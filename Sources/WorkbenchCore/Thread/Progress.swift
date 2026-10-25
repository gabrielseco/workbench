import Foundation

/// How far the latest turn has got, from the log alone. Nothing is stored; `status` derives it per call.
public struct Progress: Sendable, Equatable {
    /// `ts` of the latest `turn.started`.
    public var turnStartedAt: String?
    /// `ts` and a one-line, terminal-safe description of the newest event after that start.
    public var lastEventAt: String?
    public var lastEvent: String?
    /// `tool_use` blocks the model emitted in the latest turn.
    public var toolCalls = 0
    /// Calls the permission layer refused in the latest turn: seen in the stream as they happen.
    public var deniedCalls = 0
    /// False for a turn of a provider that has not reported any yet (its activity is normalized, and a provider that
    /// streams no tool or denial events says nothing about them): the count is then unknown, not 0.
    public var toolCallsKnown = true
    public var deniedCallsKnown = true
    /// Activity of the turn was left out (a `dropped` record): later items do not make the counts known again.
    var hasGap = false

    /// Seconds since `turnStartedAt`, nil when there is no turn or the stamp does not parse.
    public func elapsed(now: Date) -> TimeInterval? { Self.seconds(from: turnStartedAt, to: now) }

    /// Seconds since the newest event, nil when there is none.
    public func quietFor(now: Date) -> TimeInterval? { Self.seconds(from: lastEventAt, to: now) }

    /// Past this, `status` says the turn has been quiet, so stuck reads differently from slow.
    public static let quietThreshold: TimeInterval = 60

    static func seconds(from stamp: String?, to now: Date) -> TimeInterval? {
        guard let stamp, let date = parse(stamp) else { return nil }
        return max(0, now.timeIntervalSince(date))
    }

    static func parse(_ stamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: stamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }
}

extension Progress {
    /// `4m12s`, `38s`, `1h02m`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m\(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h\(String(format: "%02d", total % 3600 / 60))m"
    }

    /// The lines `status` shows under a running turn. `timeout` is the turn's limit in seconds.
    public func lines(timeout: TimeInterval?, now: Date) -> [String] {
        var lines: [String] = []
        if let elapsed = elapsed(now: now) {
            lines.append("elapsed:   \(Self.duration(elapsed))" + (timeout.map { " of \(Self.duration($0))" } ?? ""))
        }
        if let lastEvent {
            let age = quietFor(now: now)
            var line = "last:      \(lastEvent)"
            if let age { line += "  (\(Self.duration(age)) ago)" }
            lines.append(line)
            if let age, age >= Self.quietThreshold {
                lines.append("quiet:     nothing for \(Self.duration(age)); slow or stuck, the log has no more to say")
            }
        }
        let calls = toolCallsKnown ? "\(toolCalls)" : "unknown"
        lines.append("tools:     \(calls) calls, \(deniedCallsKnown ? "\(deniedCalls)" : "unknown") denied")
        return lines
    }

    /// A turn of a provider other than Claude has said nothing about tools or denials until its first such item.
    mutating func markUnreported(provider: String?) {
        guard let provider, provider != "claude" else { return }
        (toolCallsKnown, deniedCallsKnown) = (false, false)
    }

    /// Claude's stream always speaks for both.
    mutating func markReported() { (toolCallsKnown, deniedCallsKnown) = (true, true) }

    mutating func note(_ at: String, _ what: String) {
        lastEventAt = at
        lastEvent = what
    }
}

extension ThreadState {
    /// A finished turn's own count of refused calls is the authority: Claude's last line can be recovered after the
    /// output limit, with refusals that no activity event reported.
    static func reconcileDenials(ended event: Event, legacy: Bool, into state: inout ThreadState) {
        guard !legacy, event.turn == state.lastTurn, let count = event.data["permission_denials"]?.intValue else { return }
        state.progress.deniedCalls = max(state.progress.deniedCalls, count)
        state.progress.deniedCallsKnown = true
    }

    /// Folds one normalized activity into the progress of the latest turn and the reported usage.
    static func fold(activity event: Event, legacyTurns: Set<Int>, into state: inout ThreadState) {
        // A turn with `claude` lines is read through those; counting its activity too would count everything twice.
        guard !legacyTurns.contains(event.turn) else { return }
        let latest = event.turn == state.lastTurn
        let type = event.data["type"]?.stringValue ?? "?"
        if type == "usage" {
            var usage = state.reportedUsage ?? AgentUsage()
            // A provider's count is untrusted: a negative one is ignored and a sum stops at Int.max rather than trapping.
            func add(_ old: Int?, _ key: String) -> Int? {
                guard let n = event.data[key]?.intValue, n >= 0 else { return old }
                let (sum, overflow) = (old ?? 0).addingReportingOverflow(n)
                return overflow ? Int.max : sum
            }
            usage.inputTokens = add(usage.inputTokens, "input_tokens")
            usage.outputTokens = add(usage.outputTokens, "output_tokens")
            usage.cachedInputTokens = add(usage.cachedInputTokens, "cached_input_tokens")
            switch event.data["cost_usd"] {
            case .double(let d)?: usage.costUSD = (usage.costUSD ?? 0) + d
            case .int(let i)?: usage.costUSD = (usage.costUSD ?? 0) + Double(i)
            default: break
            }
            state.reportedUsage = usage
        }
        guard latest else { return }
        let provider = safeLine(event.data["provider"]?.stringValue ?? "?", limit: 30)
        switch type {
        case "tool":
            state.progress.toolCalls += 1
            state.progress.toolCallsKnown = !state.progress.hasGap
            let name = safeLine(event.data["name"]?.stringValue ?? "tool", limit: 40)
            let summary = event.data["summary"]?.stringValue.map { " " + safeLine($0, limit: 60) } ?? ""
            state.progress.note(event.ts, "tool_use \(name)\(summary)")
        case "dropped":
            // A record that counts its tool calls and refusals keeps the totals known; one that does not (an older
            // log) leaves them a floor. The marker is a sign of life either way.
            if let tools = event.data["tool_calls"]?.intValue, let denied = event.data["denied"]?.intValue {
                state.progress.toolCalls += max(0, tools)
                state.progress.deniedCalls += max(0, denied)
            } else {
                (state.progress.toolCallsKnown, state.progress.deniedCallsKnown) = (false, false)
                state.progress.hasGap = true
            }
            state.progress.note(event.ts, "\(provider) \(event.data["count"]?.intValue ?? 0) activity item(s) not recorded")
        case "permission_denied":
            state.progress.deniedCalls += 1
            state.progress.deniedCallsKnown = !state.progress.hasGap
            state.progress.note(event.ts, "tool denied")
        default:
            state.progress.note(event.ts, "\(provider) \(safeLine(type, limit: 30))")
        }
    }
}
