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
        /// The command that ran, as `check.ran` recorded it; nil for a synthetic result that has none.
        public var command: String?
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
        lines.append("tools:     \(toolCalls) calls, \(deniedCalls) denied")
        return lines
    }

    mutating func note(_ at: String, _ what: String) {
        lastEventAt = at
        lastEvent = what
    }
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
    /// What the latest turn has done so far; for `status`, which asks "working or stuck".
    public var progress: Progress

    public var isActive: Bool { decision == nil }

    public static let terminalDecisions: Set<String> = ["accepted", "discarded", "abandoned"]

    /// A pure function of the events: no file, git or clock. Unknown kinds and unknown decisions are ignored.
    public static func derive(from events: [Event], id: String) -> ThreadState {
        var state = ThreadState(
            id: id, createdAt: nil, lastTurn: 0, openTurn: nil, openCheck: nil, lastCheck: nil, decision: nil,
            lastResult: nil, totalCostUSD: 0, sessionID: nil,
            review: Review(status: .empty, turnResult: nil, check: nil, notes: [], deniedTools: []),
            progress: Progress())
        var noteIsLatest = false
        for event in events {
            switch event.kind {
            case .threadCreated:
                state.createdAt = event.ts
            case .turnStarted:
                state.lastTurn = max(state.lastTurn, event.turn)
                state.openTurn = event.turn
                state.progress = Progress(turnStartedAt: event.ts, lastEventAt: event.ts, lastEvent: "turn started")
                noteIsLatest = false
                if let session = event.data["session_id"]?.stringValue { state.sessionID = session }
            case .turnEnded:
                if state.openTurn == event.turn { state.openTurn = nil }
                state.progress.note(event.ts, "turn ended \(event.data["result"]?.stringValue ?? "")")
                state.lastResult = event.data["result"]?.stringValue
                switch event.data["cost_usd"] {
                case .double(let d)?: state.totalCostUSD += d
                case .int(let i)?: state.totalCostUSD += Double(i)
                default: break
                }
            case .checkStarted:
                state.openCheck = event.turn
                state.progress.note(event.ts, "check started")
            case .checkRan:
                if state.openCheck == event.turn { state.openCheck = nil }
                state.progress.note(event.ts, "check \(event.data["result"]?.stringValue ?? "ran")")
                let result = event.data["result"]?.stringValue
                state.lastCheck = result
                if let result {
                    state.review.check = Review.Check(
                        turn: event.turn, result: result, exitCode: event.data["exit_code"]?.intValue,
                        durationMs: event.data["duration_ms"]?.intValue,
                        outputRef: event.data["output_ref"]?.stringValue,
                        command: event.data["command"]?.stringValue)
                }
            case .threadNote:
                if let text = event.data["text"]?.stringValue {
                    // The runner writes the note with turn 0, before the turn it starts.
                    state.review.notes.append(
                        Review.Note(turn: state.lastTurn + 1, seq: event.seq, text: text))
                    noteIsLatest = state.openTurn == nil
                }
            case .claude:
                if event.turn == state.lastTurn { Self.track(event, in: &state.progress) }
                guard event.data["type"]?.stringValue == "result",
                    case .array(let denials)? = event.data["permission_denials"]
                else { break }
                if event.turn == state.lastTurn { state.progress.deniedCalls = max(state.progress.deniedCalls, denials.count) }
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

    /// Folds one stream line into the turn's progress: what the model called, what was refused, the newest line.
    static func track(_ event: Event, in progress: inout Progress) {
        // Every line is a sign of life, whatever it carries; the cases below only say it better.
        progress.note(event.ts, "claude \(safeLine(event.data["type"]?.stringValue ?? "?", limit: 30))")
        switch event.data["type"]?.stringValue {
        case "assistant":
            guard case .array(let blocks)? = event.data["message"]?["content"] else { return }
            for block in blocks where block["type"]?.stringValue == "tool_use" {
                progress.toolCalls += 1
                let name = safeLine(block["name"]?.stringValue ?? "tool", limit: 40)
                let target = denialInput(block["input"]).map { " " + safeLine($0, limit: 60) } ?? ""
                progress.note(event.ts, "tool_use \(name)\(target)")
            }
        case "user":
            guard case .array(let blocks)? = event.data["message"]?["content"] else { return }
            for block in blocks where block["type"]?.stringValue == "tool_result" {
                // The refusal is the one fixed sentence the permission layer gives the model; a command that
                // merely failed is not counted.
                let text = block["content"]?.stringValue ?? ""
                if block["is_error"] == .bool(true), text.hasPrefix("Permission for this tool use was denied") {
                    progress.deniedCalls += 1
                    progress.note(event.ts, "tool denied")
                } else {
                    progress.note(event.ts, "tool_result")
                }
            }
        default:
            break
        }
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
