import Foundation
import WorkbenchCore

/// What the Run screen shows about the latest turn, derived from the log alone. Every number here is the log's: one it does
/// not carry reads `unknown` or `not run yet`, never 0.
struct RunModel: Equatable {
    enum Kind: Equatable { case text, tool, edit, denied, gap, note }

    struct Row: Equatable, Identifiable {
        var id: Int
        var kind: Kind
        var text: String
    }

    enum Phase: Equatable {
        case working
        case checking
        /// A turn is open in the log and nothing holds the thread: its runner died. The next run records it as interrupted.
        case orphaned
        case ended(result: String, reason: String?)
    }

    var turn: Int
    var phase: Phase
    var startedAt: Date?
    var lastEventAt: Date?
    var latest: String?
    var rows: [Row]
    var toolCalls: Int?
    var deniedCalls: Int?
    var filesChanged: Int?
    var tests: String
    var spent: String
    var budget: String?
    var turnLimit: String
    /// The thread's known spend as a share of the budget, nil when either is unknown.
    var fraction: Double?

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    /// The most rows kept: a turn stores at most 1000 items, and the list never needs more than the newest of them.
    static let rowLimit = 500
    static let quietThreshold = Progress.quietThreshold

    func elapsed(now: Date) -> TimeInterval? { startedAt.map { max(0, now.timeIntervalSince($0)) } }

    func quiet(now: Date) -> TimeInterval? {
        guard phase == .working || phase == .checking, let last = lastEventAt else { return nil }
        let age = max(0, now.timeIntervalSince(last))
        return age >= Self.quietThreshold ? age : nil
    }

    /// The first words of the screen: `Turn 2 · started 4m00s ago`.
    func header(now: Date) -> String {
        guard let elapsed = elapsed(now: now) else { return "Turn \(turn)" }
        return "Turn \(turn) · started \(Progress.duration(elapsed)) ago"
    }

    /// Nil for a thread that has not run a turn.
    static func derive(
        events: [Event], state: ThreadState, runnerAlive: Bool, budgetUSD: Decimal?, turnTimeoutMin: Int?
    ) -> RunModel? {
        let turn = state.lastTurn
        guard turn > 0 else { return nil }
        let mine = events.filter { $0.turn == turn }
        var rows: [Row] = []
        var edited = Set<String>()
        var denied: [Int] = []
        var ended: Event?
        var checkRan: Event?
        for event in mine {
            switch event.kind {
            case .agentActivity: if let row = row(for: event, edited: &edited) { rows.append(row) }
            case .turnEnded: ended = event
            case .checkRan: checkRan = event
            default: break
            }
        }
        for (index, row) in rows.enumerated() where row.kind == .denied { denied.append(index) }
        // The refused calls' inputs arrive on `turn.ended`, whole; the live rows only know the tool.
        if let ended, case .array(let calls)? = ended.data["denials"], calls.count == denied.count {
            for (call, index) in zip(calls, denied) {
                let tool = call["tool"]?.stringValue ?? "call"
                let input = call["input"]?.stringValue.map { ": " + clean($0, limit: 160) } ?? ""
                rows[index].text = "denied \(tool)\(input)"
            }
        }
        if rows.count > rowLimit { rows = Array(rows.suffix(rowLimit)) }

        let progress = state.progress
        let phase: Phase
        if let ended {
            phase = .ended(result: ended.data["result"]?.stringValue ?? "ended", reason: reason(of: ended))
        } else if state.openCheck != nil {
            phase = .checking
        } else {
            phase = runnerAlive ? .working : .orphaned
        }
        let budget = budgetUSD.map { String(format: "$%.2f", NSDecimalNumber(decimal: $0).doubleValue) }
        let known = state.knownCostUSD
        var fraction: Double?
        if let known, let budgetUSD, budgetUSD > 0 { fraction = min(1, known / NSDecimalNumber(decimal: budgetUSD).doubleValue) }
        return RunModel(
            turn: turn, phase: phase, startedAt: progress.turnStartedAt.flatMap(date),
            lastEventAt: progress.lastEventAt.flatMap(date), latest: progress.lastEvent, rows: rows,
            toolCalls: progress.toolCallsKnown ? progress.toolCalls : nil,
            deniedCalls: progress.deniedCallsKnown ? progress.deniedCalls : nil,
            // A file count needs the tool rows; a gap in the activity makes it a floor, so it is unknown.
            filesChanged: progress.toolCallsKnown ? edited.count : nil,
            tests: testsText(checkRan), spent: known.map { String(format: "$%.2f", $0) } ?? "unknown", budget: budget,
            turnLimit: turnTimeoutMin.map { "\($0) min per turn" } ?? "unknown", fraction: fraction)
    }

    private static func row(for event: Event, edited: inout Set<String>) -> Row? {
        let type = event.data["type"]?.stringValue ?? "?"
        switch type {
        case "text":
            return Row(id: event.seq, kind: .text, text: clean(event.data["text"]?.stringValue ?? "", limit: 240))
        case "tool":
            let name = clean(event.data["name"]?.stringValue ?? "tool", limit: 40)
            let summary = clean(event.data["summary"]?.stringValue ?? "", limit: 160)
            let isEdit = editTools.contains(name)
            if isEdit { edited.insert(summary.isEmpty ? "\(event.seq)" : summary) }
            return Row(id: event.seq, kind: isEdit ? .edit : .tool, text: summary.isEmpty ? name : "\(name) \(summary)")
        case "permission_denied":
            let tool = clean(event.data["tool"]?.stringValue ?? "call", limit: 40)
            return Row(id: event.seq, kind: .denied, text: "denied \(tool)")
        case "dropped":
            return Row(id: event.seq, kind: .gap, text: "\(event.data["count"]?.intValue ?? 0) items not stored")
        case "diagnostic":
            return Row(id: event.seq, kind: .note, text: clean(event.data["text"]?.stringValue ?? "", limit: 160))
        default:
            return nil
        }
    }

    private static func testsText(_ check: Event?) -> String {
        guard let check, case .array(let passed)? = check.data["tests_passed"],
            case .array(let failed)? = check.data["tests_failed"]
        else { return "not run yet" }
        return failed.isEmpty ? "\(passed.count) passing" : "\(passed.count) passing, \(failed.count) failing"
    }

    private static func reason(of ended: Event) -> String? {
        let text: String? =
            switch ended.data["result"]?.stringValue {
            case "succeeded": nil
            case "stopped": "You stopped this turn."
            case "timed_out": "The turn ran past its time limit."
            case "budget_exceeded": "The turn hit its budget."
            case "interrupted": "The runner ended without finishing this turn; the log is intact."
            case "failed": "The turn failed."
            default: nil
            }
        let detail = ended.data["error"]?.stringValue.map { clean($0, limit: 240) }
        return [text, detail].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    static func date(_ stamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: stamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }

    /// Text from the log, shown on one line: no control characters, runs of space collapsed, cut at `limit`.
    static func clean(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : String($0) }.joined()
        let line = scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
