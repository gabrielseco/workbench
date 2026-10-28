@testable import WorkbenchCore

/// Builds a thread's events with the next `seq`, so a test reads as the story of a thread.
struct SpineStory {
    var events: [Event] = []

    mutating func add(_ kind: EventKind, turn: Int = 0, _ data: JSONValue = [:]) {
        events.append(
            Event(seq: events.count + 1, ts: "2026-10-28T10:00:00.000Z", turn: turn, kind: kind, data: data))
    }

    mutating func approve() { add(.goalApproved, ["hash": "h1"]) }

    mutating func turn(_ n: Int, result: String = "succeeded", cost: Double? = 1.5) {
        add(.turnStarted, turn: n, ["session_id": "s1"])
        var ended: [String: JSONValue] = ["result": .string(result)]
        if let cost { ended["cost_usd"] = .double(cost) }
        add(.turnEnded, turn: n, .object(ended))
    }

    mutating func openTurn(_ n: Int) { add(.turnStarted, turn: n, ["session_id": "s1"]) }

    mutating func decide(_ decision: String) { add(.reviewDecision, ["decision": .string(decision)]) }

    mutating func ship(number: Int = 7, head: String = "abc123") {
        add(.prOpened, ["url": .string("https://example.test/pull/\(number)"), "number": .int(number), "head_sha": .string(head)])
    }

    mutating func prRound(_ round: Int, verdict: String?, number: Int = 7, reason: String? = nil) {
        add(.prReviewStarted, ["round": .int(round), "pr": .int(number), "head_sha": "abc123"])
        var data: [String: JSONValue] = ["round": .int(round), "pr": .int(number), "ok": .bool(verdict != nil)]
        if let verdict { data["verdict"] = .string(verdict) }
        if let reason { data["reason"] = .string(reason) }
        add(.prReviewFinished, .object(data))
    }

    var state: ThreadState { ThreadState.derive(from: events, id: "t") }
}
