import Foundation

/// Where a thread stands for the person deciding about it.
public enum ReviewStatus: Sendable, Equatable {
    /// No turn has started.
    case empty
    /// A turn or its check is open.
    case running
    /// A turn ended and nothing is open: the work, even a partial one, can be reviewed.
    case awaitingReview
    /// A note was recorded after the last turn ended; the next turn has not started yet.
    case sentBack
    /// `accepted`, `discarded` or `abandoned`.
    case decided(String)
}

/// What a reviewer needs from the log. Everything is derived by `ThreadState.derive`.
public struct Review: Sendable, Equatable {
    public struct Check: Sendable, Equatable {
        /// The turn the check followed.
        public var turn: Int
        public var result: String
        public var exitCode: Int?
        public var durationMs: Int?
        public var outputRef: String?
    }

    public struct Note: Sendable, Equatable {
        /// The follow-up turn the note started.
        public var turn: Int
        public var seq: Int
        public var text: String
    }

    public struct DeniedTool: Sendable, Equatable {
        public var turn: Int
        public var tool: String
        /// The `seq` of the `claude` line that carries the denial, so a reader can open the raw event.
        public var seq: Int
        /// What it was denied for (the command, path or pattern), on one line and safe to print; nil when
        /// the denial carried nothing usable.
        public var input: String?
        /// What equal denials share: the tool and the whole input, before it was shortened for display.
        public var identity: String = ""

        /// `Bash(git push origin main)`, or just the tool name.
        public var label: String { input.map { "\(tool)(\($0))" } ?? tool }
    }

    public var status: ReviewStatus
    /// The latest turn's `result`, nil when none has ended.
    public var turnResult: String?
    /// The latest completed check, nil when none has run.
    public var check: Check?
    public var notes: [Note]
    public var deniedTools: [DeniedTool]
}

/// What the log says about a thread, derived each time it is asked for. Nothing here is stored twice.
public struct ThreadState: Sendable, Equatable {
    public var id: String
    public var createdAt: String?
    public var lastTurn: Int
    public var openTurn: Int?
    public var openCheck: Int?
    /// The latest check's `result`, nil when no check has run.
    public var lastCheck: String?
    /// `accepted`, `discarded` or `abandoned` once the thread has ended.
    public var decision: String?
    public var lastResult: String?
    public var totalCostUSD: Double
    public var sessionID: String?
    public var review: Review

    public var isActive: Bool { decision == nil }

    public static let terminalDecisions: Set<String> = ["accepted", "discarded", "abandoned"]

    /// A pure function of the events: no file, git or clock. Unknown kinds and unknown decisions are ignored.
    public static func derive(from events: [Event], id: String) -> ThreadState {
        var state = ThreadState(
            id: id, createdAt: nil, lastTurn: 0, openTurn: nil, openCheck: nil, lastCheck: nil, decision: nil,
            lastResult: nil, totalCostUSD: 0, sessionID: nil,
            review: Review(status: .empty, turnResult: nil, check: nil, notes: [], deniedTools: []))
        var noteIsLatest = false
        for event in events {
            switch event.kind {
            case .threadCreated:
                state.createdAt = event.ts
            case .turnStarted:
                state.lastTurn = max(state.lastTurn, event.turn)
                state.openTurn = event.turn
                noteIsLatest = false
                if let session = event.data["session_id"]?.stringValue { state.sessionID = session }
            case .turnEnded:
                if state.openTurn == event.turn { state.openTurn = nil }
                state.lastResult = event.data["result"]?.stringValue
                switch event.data["cost_usd"] {
                case .double(let d)?: state.totalCostUSD += d
                case .int(let i)?: state.totalCostUSD += Double(i)
                default: break
                }
            case .checkStarted:
                state.openCheck = event.turn
            case .checkRan:
                if state.openCheck == event.turn { state.openCheck = nil }
                let result = event.data["result"]?.stringValue
                state.lastCheck = result
                if let result {
                    state.review.check = Review.Check(
                        turn: event.turn, result: result, exitCode: event.data["exit_code"]?.intValue,
                        durationMs: event.data["duration_ms"]?.intValue,
                        outputRef: event.data["output_ref"]?.stringValue)
                }
            case .threadNote:
                if let text = event.data["text"]?.stringValue {
                    // The runner writes the note with turn 0, before the turn it starts.
                    state.review.notes.append(
                        Review.Note(turn: state.lastTurn + 1, seq: event.seq, text: text))
                    noteIsLatest = state.openTurn == nil
                }
            case .claude:
                guard event.data["type"]?.stringValue == "result",
                    case .array(let denials)? = event.data["permission_denials"]
                else { break }
                // The turn's final result line is the one whose length `turn.ended.permission_denials`
                // records, so an earlier result line of the same turn (a replay) is replaced, not added.
                state.review.deniedTools.removeAll { $0.turn == event.turn }
                for denial in denials {
                    guard let tool = denial["tool_name"]?.stringValue else { continue }
                    let identity = tool + "\u{0}" + (Self.denialRawInput(denial["tool_input"]) ?? "")
                    state.review.deniedTools.append(
                        Review.DeniedTool(
                            turn: event.turn, tool: Self.safeLine(tool, limit: 60), seq: event.seq,
                            input: Self.denialInput(denial["tool_input"]), identity: String(identity.hashValue)))
                }
            case .reviewDecision:
                if let decision = event.data["decision"]?.stringValue, terminalDecisions.contains(decision) {
                    state.decision = decision
                }
            default:
                break
            }
        }
        state.review.turnResult = state.lastResult
        if let decision = state.decision {
            state.review.status = .decided(decision)
        } else if state.openTurn != nil || state.openCheck != nil {
            state.review.status = .running
        } else if state.lastTurn == 0 {
            state.review.status = .empty
        } else if noteIsLatest {
            state.review.status = .sentBack
        } else {
            state.review.status = .awaitingReview
        }
        return state
    }

    /// Text from the log that will be printed in a terminal: one line, no control characters or escape
    /// sequences, cut at `limit` characters.
    static func safeLine(_ text: String, limit: Int) -> String {
        var out = ""
        var lastWasSpace = false
        var scalars = text.unicodeScalars.makeIterator()
        func emit(_ scalar: Unicode.Scalar, space: Bool) {
            if space {
                if lastWasSpace { return }
                out.unicodeScalars.append(" ")
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        while let scalar = scalars.next() {
            if scalar == "\u{1B}" {
                // A whole escape sequence goes, not just the ESC: CSI up to its final byte, OSC up to BEL or
                // ST, any other ESC with the one character it introduces.
                guard let kind = scalars.next() else { break }
                if kind == "[" {
                    while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
                } else if kind == "]" {
                    while let next = scalars.next() {
                        if next == "\u{07}" { break }
                        if next == "\u{1B}" { _ = scalars.next(); break }
                    }
                }
                continue
            }
            let isBreak = scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == "\u{2028}"
                || scalar == "\u{2029}" || scalar == "\u{85}"
            let isControl = scalar.properties.generalCategory == .control || scalar.value == 0x7F
            if isControl && !isBreak { continue }
            emit(scalar, space: isBreak || scalar == " ")
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.count > limit ? String(out.prefix(limit - 1)) + "…" : out
    }

    /// The input as written, for telling denials apart. Never printed.
    static func denialRawInput(_ input: JSONValue?) -> String? {
        guard let input else { return nil }
        for key in ["command", "file_path", "path", "notebook_path", "url", "pattern", "query"] {
            if let value = input[key]?.stringValue { return value }
        }
        return nil
    }

    /// What a denied call was for: the command, path, URL or pattern in its `tool_input`.
    static func denialInput(_ input: JSONValue?) -> String? {
        guard let input else { return nil }
        let keys = ["command", "file_path", "path", "notebook_path", "url", "pattern", "query"]
        for key in keys {
            if let value = input[key]?.stringValue {
                let line = safeLine(value, limit: 100)
                if !line.isEmpty { return line }
            }
        }
        return nil
    }
}
