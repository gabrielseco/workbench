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

        init(contents: EventLogContents, runnerAlive: Bool) { (self.contents, self.runnerAlive) = (contents, runnerAlive) }

        mutating func items() -> [FeedItem] {
            var ended: [Int: Event] = [:]
            for event in contents.events where event.kind == .turnEnded { ended[event.turn] = event }
            for event in contents.events { add(event, ended: ended[event.turn]) }
            flush()
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
                push(event, .decision(short(event.data["decision"]?.stringValue ?? "decided")))
            case .prOpened:
                push(event, .pullRequest(number: event.data["number"]?.intValue, url: event.data["url"]?.stringValue.map(short)))
            case .prReviewFinished:
                push(
                    event,
                    .prReview(
                        round: event.data["round"]?.intValue, verdict: event.data["verdict"]?.stringValue.map(short),
                        ok: event.data["ok"] == true))
            default:
                break
            }
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
            case "text":
                push(event, .agentText(ThreadState.safeLine(event.data["text"]?.stringValue ?? "", limit: Feed.textLimit)))
            case "tool":
                tool(event)
            case "permission_denied":
                push(event, .denied(tool: ThreadState.safeLine(event.data["tool"]?.stringValue ?? "call", limit: 40)))
            case "dropped":
                push(event, .notice(.activityNotStored(count: event.data["count"]?.intValue ?? 0)))
            default:
                break
            }
        }

        private mutating func tool(_ event: Event) {
            let name = ThreadState.safeLine(event.data["name"]?.stringValue ?? "tool", limit: 40)
            let summary = short(event.data["summary"]?.stringValue ?? "")
            if Feed.editTools.contains(name) {
                // A file edited again in the same turn is the same row: the feed says what changed, not how often.
                let file = summary.isEmpty ? "\(event.seq)" : summary
                guard edited[event.turn, default: []].insert(file).inserted else { return }
                push(event, .edit(file: file, tool: name))
                return
            }
            let label = summary.isEmpty ? name : "\(name) \(summary)"
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
            notices[first] = FeedItem(
                id: "\(items[first].seq).folded", seq: items[first].seq, turn: turn,
                kind: .notice(.activityFolded(count: gone.count)))
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
