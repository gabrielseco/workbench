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
        /// The tests the output showed finishing; nil when the runner's format was not known.
        public var tests: CheckTests?
    }

    /// The latest `judge.ran`: the advisory judge's verdict for a turn, or why there was none.
    public struct Judge: Sendable, Equatable {
        public var turn: Int
        public var verdict: JudgeVerdict?
        public var costUSD: Double?
        public var failure: String?
    }

    /// The latest `pr_review.*` event: Codex's review of the shipped pull request, or why a round has no verdict.
    public struct PRReview: Sendable, Equatable {
        public var round: Int
        public var pr: Int?
        /// The commit of the pull request that was reviewed.
        public var headSHA: String?
        /// `clean` or `fix`; nil when the round has no verdict.
        public var verdict: String?
        public var failure: String?
        /// Relative to the thread's directory.
        public var findingsPath: String?
        /// What the reviewer's provider reported it cost (Claude); nil when it reports none (Codex), never 0.
        public var costUSD: Double?
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
        /// The whole input as `turn.ended.denials` recorded it (one line, safe to print, 4096 characters at most),
        /// nil for a log from before that field or a turn that did not record it.
        public var fullInput: String?
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
    /// The latest verifier run, nil when none has run or been skipped. Advisory.
    public var verifier: Verifier?
    /// The latest judge run, nil when none has run. Advisory.
    public var judge: Judge?
    public var notes: [Note]
    public var deniedTools: [DeniedTool]
    /// The latest pull request review round, nil when none has run.
    public var prReview: PRReview?
}

/// A plan event as `status` and `review` show it: the plan that was made or edited, or why there is none.
public struct PlanRecord: Sendable, Equatable {
    public var ok: Bool
    public var source: PlanSource
    /// The model the plan turn was asked for, read from the logged command; nil for an edit or an old log.
    public var model: String?
    public var costUSD: Double?
    /// The plan file, relative to the thread's folder.
    public var ref: String?
    public var sha256: String?
    public var bytes: Int?
    public var goalHash: String?
    public var baseCommit: String?
    public var truncated: Bool
    public var failure: String?

    init(_ event: Event) {
        // A start is replaced by the `plan.ended` that follows; if none does, the plan was cut off.
        let started = event.kind == .planStarted
        let ok = event.kind == .planEdited || (!started && event.data["ok"] == true)
        var cost: Double?
        switch event.data["cost_usd"] {
        case .double(let d)?: cost = d
        case .int(let i)?: cost = Double(i)
        default: break
        }
        var model: String?
        if case .array(let argv)? = event.data["argv"], let at = argv.firstIndex(of: "--model"), at + 1 < argv.count {
            model = argv[at + 1].stringValue
        }
        self.ok = ok
        self.source = event.kind == .planEdited ? .edited : .generated
        self.model = model
        self.costUSD = cost
        self.ref = ok ? event.data["plan_ref"]?.stringValue : nil
        self.sha256 = ok ? event.data["sha256"]?.stringValue : nil
        self.bytes = ok ? event.data["bytes"]?.intValue : nil
        self.goalHash = event.data["goal_hash"]?.stringValue
        self.baseCommit = event.data["base_commit"]?.stringValue
        self.truncated = event.data["truncated"] == true
        if ok {
            self.failure = nil
        } else if started {
            self.failure = "started and never recorded a result (still running, or it was interrupted)"
        } else {
            self.failure = event.data["reason"]?.stringValue ?? "no reason recorded"
        }
    }
}

/// Where a review follow-up thread came from, as its `thread.created` recorded it. The tree is derived from these
/// links; nothing stores it twice.
public struct ThreadLineage: Sendable, Equatable {
    /// The thread this one follows (itself a follow-up from the second round on).
    public var parent: String
    /// The thread that opened the pull request.
    public var root: String
    /// 1 for the first follow-up of the root, 2 for the next.
    public var round: Int
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
    /// True once a turn ended without a `cost_usd`: the total is then not known, and is never shown as a sum or as 0.
    public var costUnknown = false
    public var sessionID: String?
    public var sessionProvider: String?  // nil: a log from before turns named one (Claude)
    public var review: Review
    /// What the latest turn has done so far; for `status`, which asks "working or stuck".
    public var progress: Progress
    /// Set for a review follow-up, nil for a thread someone started.
    public var lineage: ThreadLineage?
    /// The latest plan event, nil when none has run: a plan turn that started, ended or failed, or an edit.
    public var plan: PlanRecord?
    /// The latest plan that was kept (generated or edited), nil when none was. A later failed plan does not hide it.
    public var currentPlan: PlanRecord?
    /// What the plan turns cost, apart from the turns' `totalCostUSD`. An edit is free.
    public var planCostUSD: Double = 0
    /// The hash the latest `goal.approved` bound, so a plan made for another version reads as stale.
    public var approvedGoalHash: String?
    public var approvedAgent: ApprovedAgent?  // what the latest `goal.approved` bound; nil before P9
    /// The provider and model each responsibility (`run`, `judge`, `review`) last used, keyed by name. A role that
    /// never ran has no entry; one whose records predate provider selection reads as its old default (`recorded` false).
    public var agentUse: [String: AgentUse] = [:]
    /// Usage the `agent.activity` events of non-Claude turns reported, summed per field. A field no provider ever
    /// reported is nil, never 0; nil when none did. Claude's cost is in `totalCostUSD`.
    public var reportedUsage: AgentUsage?

    /// The turns' cost, nil when any turn did not report one (`--json` says null, text says `unknown`).
    public var knownCostUSD: Double? { costUnknown ? nil : totalCostUSD }

    public var isActive: Bool { decision == nil }

    public static let terminalDecisions: Set<String> = ["accepted", "discarded", "abandoned"]

    /// The `parent`, `root` and `round` of a follow-up's `thread.created`, nil when any is missing or not a thread id.
    private static func lineage(_ event: Event) -> ThreadLineage? {
        guard let parent = event.data["parent"]?.stringValue, let root = event.data["root"]?.stringValue,
            let round = event.data["round"]?.intValue, SafeNames.isThreadID(parent), SafeNames.isThreadID(root)
        else { return nil }
        return ThreadLineage(parent: parent, root: root, round: round)
    }

    /// A `pr_review.started` or `pr_review.finished` event as the review shows it. A round that only started is
    /// replaced by the `finished` that follows; if none does, it was cut off.
    private static func prReviewRound(_ event: Event) -> Review.PRReview {
        if event.kind == .prReviewStarted {
            return Review.PRReview(
                round: event.data["round"]?.intValue ?? 0, pr: event.data["pr"]?.intValue,
                headSHA: event.data["head_sha"]?.stringValue, verdict: nil,
                failure: "started and never recorded a result (still running, or it was interrupted)", findingsPath: nil)
        }
        let verdict = event.data["verdict"]?.stringValue
        let ok = event.data["ok"] == true && (verdict == "clean" || verdict == "fix")
        return Review.PRReview(
            round: event.data["round"]?.intValue ?? 0, pr: event.data["pr"]?.intValue,
            headSHA: event.data["head_sha"]?.stringValue, verdict: ok ? verdict : nil,
            failure: ok ? nil : safeLine(event.data["reason"]?.stringValue ?? "no reason recorded", limit: 300),
            findingsPath: event.data["findings_path"]?.stringValue, costUSD: reportedCost(event))
    }

    /// The `cost_usd` an event recorded; nil when the provider reported none.
    private static func reportedCost(_ event: Event) -> Double? {
        switch event.data["cost_usd"] {
        case .double(let d)?: d
        case .int(let i)?: Double(i)
        default: nil
        }
    }

    /// A `judge.ran` event as the review shows it. Entries that do not read as a verdict are left out, so a
    /// damaged line shows as a run without one rather than as a verdict that was never given.
    private static func judgeRun(_ event: Event) -> Review.Judge {
        let cost: Double? =
            switch event.data["cost_usd"] {
            case .double(let d)?: d
            case .int(let i)?: Double(i)
            default: nil
            }
        guard event.data["ok"] == true, case .array(let entries)? = event.data["criteria"] else {
            return Review.Judge(
                turn: event.turn, verdict: nil, costUSD: cost,
                failure: event.data["reason"]?.stringValue ?? "no verdict")
        }
        let criteria = entries.compactMap { entry -> JudgeCriterion? in
            guard let id = entry["id"]?.stringValue, case .bool(let met)? = entry["met"] else { return nil }
            var evidence: [String] = []
            if case .array(let items)? = entry["evidence"] { evidence = items.compactMap(\.stringValue) }
            return JudgeCriterion(id: id, met: met, evidence: evidence)
        }
        var concerns: [String] = []
        if case .array(let items)? = event.data["concerns"] { concerns = items.compactMap(\.stringValue) }
        return Review.Judge(
            turn: event.turn, verdict: JudgeVerdict(criteria: criteria, concerns: concerns), costUSD: cost, failure: nil)
    }

    private static func tests(in event: Event) -> CheckTests? {
        guard case .array(let passed)? = event.data["tests_passed"], case .array(let failed)? = event.data["tests_failed"]
        else { return nil }
        return CheckTests(
            passed: passed.compactMap(\.stringValue), failed: failed.compactMap(\.stringValue),
            truncated: event.data["tests_truncated"] == true)
    }

    /// The runs that only advise: the judge, the plan and the pull request review. Each start is replaced by the
    /// end that follows; if none does, the run was cut off.
    private static func applyAdvisory(_ event: Event, to state: inout ThreadState) {
        switch event.kind {
        case .judgeStarted:
            state.review.judge = Review.Judge(
                turn: event.turn, verdict: nil, costUSD: nil,
                failure: "started and never recorded a result (still running, or it was interrupted)")
        case .judgeRan:
            state.review.judge = judgeRun(event)
        case .planStarted, .planEnded, .planEdited:
            let record = PlanRecord(event)
            state.plan = record
            if record.ok { state.currentPlan = record }
            if event.kind == .planEnded { state.planCostUSD += record.costUSD ?? 0 }
        case .goalApproved:
            (state.approvedGoalHash, state.approvedAgent) = (event.data["hash"]?.stringValue, ApprovedAgent(event))
        default:
            state.review.prReview = prReviewRound(event)
        }
    }

    /// A pure function of the events: no file, git or clock. Unknown kinds and unknown decisions are ignored.
    public static func derive(from events: [Event], id: String) -> ThreadState {
        var state = ThreadState(
            id: id, createdAt: nil, lastTurn: 0, openTurn: nil, openCheck: nil, lastCheck: nil,
            decision: nil, lastResult: nil, totalCostUSD: 0, sessionID: nil,
            review: Review(
                status: .empty, turnResult: nil, check: nil, verifier: nil, judge: nil, notes: [], deniedTools: [],
                prReview: nil),
            progress: Progress())
        var noteIsLatest = false
        var verifierProof: [ProofFile] = []
        // A turn is read through one shape: verbatim `claude` lines when it has any, else `agent.activity`.
        let legacyTurns = Set(events.filter { $0.kind == .claude }.map(\.turn))
        for event in events {
            Self.applyAgent(event, to: &state.agentUse)
            switch event.kind {
            case .threadCreated:
                state.createdAt = event.ts
                state.lineage = Self.lineage(event)
            case .turnStarted:
                state.lastTurn = max(state.lastTurn, event.turn)
                state.openTurn = event.turn
                state.progress = Progress(turnStartedAt: event.ts, lastEventAt: event.ts, lastEvent: "turn started")
                noteIsLatest = false
                state.sessionProvider = event.data["provider"]?.stringValue
                state.progress.markUnreported(provider: state.sessionProvider)
                if let session = event.data["session_id"]?.stringValue { state.sessionID = session }
            case .turnEnded:
                if state.openTurn == event.turn { state.openTurn = nil }
                state.progress.note(event.ts, "turn ended \(event.data["result"]?.stringValue ?? "")")
                state.lastResult = event.data["result"]?.stringValue
                Self.attachFullInputs(event, to: &state.review.deniedTools)
                switch event.data["cost_usd"] {
                case .double(let d)?: state.totalCostUSD += d
                case .int(let i)?: state.totalCostUSD += Double(i)
                default: state.costUnknown = true
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
                        command: event.data["command"]?.stringValue, tests: Self.tests(in: event))
                }
            case .judgeStarted, .judgeRan, .planStarted, .planEnded, .planEdited, .goalApproved, .prReviewStarted,
                .prReviewFinished:
                Self.applyAdvisory(event, to: &state)
            case .verifierStarted, .verifierEnded, .verifierSkipped, .proofAdded:
                Self.applyVerifier(event, to: &state, pending: &verifierProof)
            case .threadNote:
                if let text = event.data["text"]?.stringValue {
                    // The runner writes the note with turn 0, before the turn it starts.
                    state.review.notes.append(
                        Review.Note(turn: state.lastTurn + 1, seq: event.seq, text: text))
                    noteIsLatest = state.openTurn == nil
                }
            case .claude:
                if event.turn == state.lastTurn {
                    state.progress.markReported()
                    Self.track(event, in: &state.progress)
                }
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
            case .agentActivity:
                Self.fold(activity: event, legacyTurns: legacyTurns, into: &state)
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

    /// Puts the full inputs `turn.ended` recorded on the turn's entries, which came from the same result line in
    /// the same order. A different count means they are not the same list, so nothing is attached.
    static func attachFullInputs(_ ended: Event, to tools: inout [Review.DeniedTool]) {
        guard case .array(let calls)? = ended.data["denials"] else { return }
        let indices = tools.indices.filter { tools[$0].turn == ended.turn }
        guard indices.count == calls.count else { return }
        for (index, call) in zip(indices, calls) {
            guard let text = call["input"]?.stringValue else { continue }
            let line = safeLine(text, limit: 4096)
            if !line.isEmpty { tools[index].fullInput = line }
        }
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
