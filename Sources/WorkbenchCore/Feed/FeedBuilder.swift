import Foundation

extension Feed {
    /// One pass over the events: each becomes at most one item, consecutive tool calls become one group, and a turn's activity is
    /// folded to `maxActivityPerTurn` afterwards.
    struct Builder {
        let contents: EventLogContents
        let runnerAlive: Bool
        private var out: [FeedItem] = []
        private struct ToolGroup {
            var seq: Int
            var turn: Int
            var count: Int
            var summaries: [String]
        }
        private var group: ToolGroup?
        private var edited: [Int: Set<String>] = [:]
        /// The refused calls of each turn as `turn.ended` recorded them, and how many `permission_denied` rows have been seen.
        private var denials: [Int: [(tool: String, input: String?)]] = [:]
        private var deniedSeen: [Int: Int] = [:]
        private var deniedRows: [Int: Int] = [:]
        private var lastPlan: [Int: [FeedItem.PlanTask]] = [:]
        private var planSeen = Set<Int>()
        /// The last few calls of each turn, every one of them (an edit shown once in the feed is still the latest call when it repeats).
        private var recent: [Int: [String]] = [:]

        init(contents: EventLogContents, runnerAlive: Bool) { (self.contents, self.runnerAlive) = (contents, runnerAlive) }

        mutating func items() -> [FeedItem] {
            var ended: [Int: Event] = [:]
            for event in contents.events where event.kind == .turnEnded {
                ended[event.turn] = event
                if case .array(let calls)? = event.data["denials"] {
                    denials[event.turn] = calls.map {
                        (ThreadState.safeLine($0["tool"]?.stringValue ?? "call", limit: 40), $0["input"]?.stringValue.map(short))
                    }
                }
            }
            for event in contents.events where event.kind == .agentActivity {
                if event.data["type"]?.stringValue == "permission_denied" { deniedRows[event.turn, default: 0] += 1 }
            }
            for event in contents.events where event.kind == .agentActivity && event.data["type"]?.stringValue == "plan" {
                guard case .array(let entries)? = event.data["items"] else { continue }
                // An empty list is the agent clearing its tasks, not a damaged record: it replaces the last one.
                if entries.isEmpty {
                    lastPlan[event.turn] = []
                    continue
                }
                let tasks = entries.prefix(AgentActivityRecord.maxPlanItems).compactMap { entry -> FeedItem.PlanTask? in
                    guard let text = entry["text"]?.stringValue, !text.isEmpty else { return nil }
                    let state: FeedItem.PlanTask.State =
                        switch entry["status"]?.stringValue {
                        case "done": .done
                        case "in_progress": .working
                        default: .pending
                        }
                    return FeedItem.PlanTask(text: short(text), state: state)
                }
                if !tasks.isEmpty { lastPlan[event.turn] = tasks }
            }
            for event in contents.events { add(event, ended: ended[event.turn]) }
            flush()
            for index in out.indices {
                if case .turn = out[index].kind { out[index].latest = recent[out[index].turn] ?? [] }
            }
            return Feed.fold(out)
        }

        private mutating func push(_ event: Event, _ kind: FeedItem.Kind, suffix: String = "") {
            flush()
            out.append(FeedItem(id: "\(event.seq)\(suffix)", seq: event.seq, turn: event.turn, kind: kind))
        }

        private mutating func flush() {
            guard let open = group else { return }
            group = nil
            let kind = FeedItem.Kind.toolGroup(count: open.count, summaries: open.summaries)
            out.append(FeedItem(id: "\(open.seq)", seq: open.seq, turn: open.turn, kind: kind))
        }

        private mutating func add(_ event: Event, ended: Event?) {
            switch event.kind {
            case .threadNote:
                push(event, .userNote(text: ThreadState.safeLine(event.data["text"]?.stringValue ?? "", limit: Feed.noteLimit)))
            case .turnStarted:
                let how = phase(of: event.turn, ended: ended)
                push(event, .turn(number: event.turn, phase: how, durationMs: duration(ended), costUSD: cost(ended)))
            case .turnEnded:
                refusalsWithoutRows(event)
            case .agentActivity:
                activity(event)
            case .checkRan:
                push(
                    event,
                    .check(
                        result: event.data["result"]?.stringValue ?? "unknown",
                        command: event.data["command"]?.stringValue.map(short), durationMs: event.data["duration_ms"]?.intValue))
            case .judgeRan:
                push(event, judge(event))
            case .verifierEnded:
                push(event, verify(event))
            case .reviewDecision:
                let decision = event.data["decision"]?.stringValue ?? "decided"
                // A task run that ended its own thread says how the run went, not that it was abandoned.
                let lastResult = contents.events.last { $0.kind == .turnEnded && $0.seq < event.seq }?.data["result"]?.stringValue
                if decision == "abandoned", event.data["by"]?.stringValue == "task", let lastResult {
                    push(event, .decision(lastResult == "succeeded" ? "succeeded" : short(lastResult)))
                } else {
                    push(event, .decision(short(decision)))
                }
            case .prOpened:
                push(event, .pullRequest(number: event.data["number"]?.intValue, url: event.data["url"]?.stringValue.map(short)))
            case .prReviewFinished:
                push(
                    event,
                    .prReview(
                        round: event.data["round"]?.intValue, verdict: event.data["verdict"]?.stringValue.map(short),
                        ok: event.data["ok"] == true))
            case .reviewStageFinished:
                guard let name = event.data["stage"]?.stringValue.map(short) else { break }
                push(
                    event,
                    .stage(
                        name: name, round: event.data["round"]?.intValue, verdict: event.data["verdict"]?.stringValue.map(short),
                        ok: event.data["ok"] == true, proof: stageProof(of: event, named: name)))
            default:
                break
            }
        }

        /// The screenshots the round was given, from the `started` it closes: the latest start of that stage before the finish.
        private func stageProof(of finish: Event, named name: String) -> [String] {
            let start = contents.events.last {
                $0.kind == .reviewStageStarted && $0.seq < finish.seq && $0.data["stage"]?.stringValue == name
            }
            guard case .array(let files)? = start?.data["proof"] else { return [] }
            return files.compactMap { $0.stringValue.map(short) }
        }

        private func short(_ text: String) -> String { ThreadState.safeLine(text, limit: Feed.summaryLimit) }

        private func phase(of turn: Int, ended: Event?) -> FeedItem.Phase {
            if let ended { return .ended(result: short(ended.data["result"]?.stringValue ?? "ended")) }
            if turn == contents.openTurn { return runnerAlive ? .working : .orphaned }
            return .unrecorded
        }

        private func duration(_ ended: Event?) -> Int? { ended?.data["duration_ms"]?.intValue }

        private func cost(_ ended: Event?) -> Double? {
            switch ended?.data["cost_usd"] {
            case .double(let value)?: value
            case .int(let value)?: Double(value)
            default: nil
            }
        }

        private func judge(_ event: Event) -> FeedItem.Kind {
            guard event.data["ok"] == true, case .array(let entries)? = event.data["criteria"] else {
                return .judge(ok: false, criteria: 0, unmet: 0, concerns: 0)
            }
            let unmet = entries.filter { $0["met"] != true }.count
            var concerns = 0
            if case .array(let list)? = event.data["concerns"] { concerns = list.count }
            return .judge(ok: true, criteria: entries.count, unmet: unmet, concerns: concerns)
        }

        private func verify(_ event: Event) -> FeedItem.Kind {
            var proofs: [String] = []
            if case .array(let files)? = event.data["files"] { proofs = files.compactMap { $0["name"]?.stringValue.map(short) } }
            return .verify(ok: event.data["ok"] == true, reason: event.data["reason"]?.stringValue.map(short), proofs: proofs)
        }

        private mutating func activity(_ event: Event) {
            switch event.data["type"]?.stringValue ?? "" {
            case "plan":
                // Each update replaces the list: the turn shows one row, where it first appeared, with the last list.
                guard planSeen.insert(event.turn).inserted, let tasks = lastPlan[event.turn], !tasks.isEmpty else { return }
                push(event, .plan(tasks: tasks))
            case "text":
                push(event, .agentText(ThreadState.safeLine(event.data["text"]?.stringValue ?? "", limit: Feed.textLimit)))
            case "tool":
                tool(event)
            case "permission_denied":
                let index = deniedSeen[event.turn, default: 0]
                deniedSeen[event.turn] = index + 1
                // The row's own input is there while the turn runs; older logs and Codex have it only on `turn.ended`, whole, and
                // matched by order: the rows are the first refusals of the turn.
                let calls = denials[event.turn] ?? []
                let own = event.data["input"]?.stringValue.map(short)
                let input = own ?? (index < calls.count ? calls[index].input : nil)
                let tool = ThreadState.safeLine(event.data["tool"]?.stringValue ?? "call", limit: 40)
                push(event, .denied(tool: tool, input: input))
            case "dropped":
                push(event, .notice(.activityNotStored(count: event.data["count"]?.intValue ?? 0)))
            default:
                break
            }
        }

        /// Refusals the activity rows did not keep (the turn passed its cap, or the log was compacted) are still on `turn.ended`.
        private mutating func refusalsWithoutRows(_ event: Event) {
            let calls = denials[event.turn] ?? []
            let rows = deniedSeen[event.turn, default: 0]
            guard calls.count > rows else { return }
            for (offset, call) in calls[rows...].enumerated() {
                push(event, .denied(tool: call.tool, input: call.input), suffix: ".\(offset)")
            }
        }

        private mutating func tool(_ event: Event) {
            let name = ThreadState.safeLine(event.data["name"]?.stringValue ?? "tool", limit: 40)
            let summary = short(event.data["summary"]?.stringValue ?? "")
            let label = summary.isEmpty ? name : "\(name) \(summary)"
            recent[event.turn] = Array((recent[event.turn, default: []] + [label]).suffix(Feed.summariesPerGroup))
            if Feed.editTools.contains(name) {
                // A file edited again in the same turn is the same row: the feed says what changed, not how often.
                // Two files are the same only when the whole recorded path is, not the part that fits on a row.
                let whole = ThreadState.safeLine(event.data["summary"]?.stringValue ?? "", limit: 4_096)
                let file = summary.isEmpty ? "\(event.seq)" : summary
                guard edited[event.turn, default: []].insert(whole.isEmpty ? file : whole).inserted else { return }
                push(event, .edit(file: file, tool: name))
                return
            }
            if var open = group, open.turn == event.turn {
                open.count += 1
                if open.summaries.count < Feed.summariesPerGroup { open.summaries.append(label) }
                group = open
            } else {
                flush()
                group = ToolGroup(seq: event.seq, turn: event.turn, count: 1, summaries: [label])
            }
        }
    }

    /// Folds a turn's activity items to `maxActivityPerTurn`: a refused call is never folded, the rest keep their head and tail,
    /// and one notice says how many went. Items of other kinds are not activity and are left alone.
    static func fold(_ items: [FeedItem]) -> [FeedItem] {
        var byTurn: [Int: [Int]] = [:]
        for (index, item) in items.enumerated() where isActivity(item.kind) { byTurn[item.turn, default: []].append(index) }
        var drop = Set<Int>()
        var notices: [Int: FeedItem] = [:]
        for (turn, indices) in byTurn where indices.count > maxActivityPerTurn {
            let denied = indices.filter { isDenied(items[$0].kind) }.prefix(maxActivityPerTurn - 1)
            let others = indices.filter { !isDenied(items[$0].kind) }
            let budget = max(0, maxActivityPerTurn - 1 - denied.count)
            let head = budget - budget / 2
            let kept = Set(others.prefix(head)).union(others.suffix(budget / 2)).union(denied)
            let gone = indices.filter { !kept.contains($0) }
            guard let first = gone.first else { continue }
            drop.formUnion(gone)
            let refused = gone.filter { isDenied(items[$0].kind) }.count
            notices[first] = FeedItem(
                id: "\(items[first].seq).folded", seq: items[first].seq, turn: turn,
                kind: .notice(.activityFolded(count: gone.count, refusals: refused)))
        }
        guard !drop.isEmpty else { return items }
        var out: [FeedItem] = []
        for (index, item) in items.enumerated() {
            if let notice = notices[index] { out.append(notice) }
            if !drop.contains(index) { out.append(item) }
        }
        return out
    }

    private static func isDenied(_ kind: FeedItem.Kind) -> Bool {
        if case .denied = kind { return true }
        return false
    }

    private static func isActivity(_ kind: FeedItem.Kind) -> Bool {
        switch kind {
        case .agentText, .toolGroup, .edit, .denied, .notice(.activityNotStored): true
        default: false
        }
    }
}
