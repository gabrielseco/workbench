import Foundation

/// A thread's log, goal and state as a list of `FeedItem`s (P22 slice 2). Pure: no I/O and no clock, so a test feeds it a fixture
/// and the same function serves the app, the CLI and anything else that wants the conversation.
public enum Feed {
    /// What the goal file says, as little as the feed needs. nil when there is no readable goal file.
    public struct GoalSummary: Sendable, Equatable {
        public var title: String?
        public var approval: ApprovalState
        public var criteria: Int

        public init(title: String?, approval: ApprovalState, criteria: Int) {
            (self.title, self.approval, self.criteria) = (title, approval, criteria)
        }
    }

    /// Items one turn's activity may use. A turn is at most `maxActivityPerTurn` plus its own turn, check, judge and verify rows.
    public static let maxActivityPerTurn = 50
    /// Items in a whole feed; the earliest are dropped and a notice says how many.
    public static let maxItems = 1_000
    public static let textLimit = 400
    public static let noteLimit = 2_000
    public static let summaryLimit = 160
    public static let summariesPerGroup = 3
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    public static func items(
        contents: EventLogContents, goal: GoalSummary?, state: ThreadState, spine: ThreadSpine, attention: Attention = .none,
        runnerAlive: Bool = true
    ) -> [FeedItem] {
        var builder = Builder(contents: contents, runnerAlive: runnerAlive)
        var body = builder.items()
        let card = goalItems(goal: goal, events: contents.events)
        // The goal card sits before the first thing that happened at or after it; with no goal events it opens the feed.
        let at = card.position.map { seq in body.firstIndex { $0.seq > seq } ?? body.count } ?? 0
        body.insert(contentsOf: card.items, at: at)
        // The damage notice and the next-step card are never the ones dropped to stay small.
        var items = [FeedItem]()
        if let notice = damage(contents) { items.append(notice) }
        items += bounded(body, room: maxItems - items.count - 1)
        items.append(next(spine: spine, state: state, attention: attention, lastSeq: contents.events.last?.seq ?? 0))
        return items
    }

    // MARK: Whole-feed pieces

    private static func damage(_ contents: EventLogContents) -> FeedItem? {
        if let first = contents.problems.first {
            let text = ThreadState.safeLine("\(first)", limit: summaryLimit)
            let kind = FeedItem.Kind.notice(.logDamaged(problems: contents.problems.count, first: text))
            return FeedItem(id: "damage", seq: 0, turn: 0, kind: kind)
        }
        if contents.truncatedTail != nil { return FeedItem(id: "damage", seq: 0, turn: 0, kind: .notice(.logTailCut)) }
        return nil
    }

    /// One card for the goal, at the first goal event, and a notice after it when the file changed since approval.
    private static func goalItems(goal: GoalSummary?, events: [Event]) -> (items: [FeedItem], position: Int?) {
        let first = events.first { $0.kind == .goalSaved || $0.kind == .goalApproved }
        guard goal != nil || first != nil else { return ([], nil) }
        let seq = first?.seq ?? 0
        let hash = events.last { $0.kind == .goalApproved && $0.data["hash"]?.stringValue != nil }?.data["hash"]?.stringValue
            ?? events.last { $0.kind == .goalSaved }?.data["hash"]?.stringValue
        var items = [
            FeedItem(
                id: "goal", seq: seq, turn: 0,
                kind: .goalCard(
                    title: goal?.title.map { ThreadState.safeLine($0, limit: summaryLimit) }, approval: goal?.approval,
                    criteria: goal?.criteria ?? 0, hash: hash.map { ThreadState.safeLine($0, limit: 80) }))
        ]
        if goal?.approval == .stale {
            items.append(FeedItem(id: "goal.stale", seq: seq, turn: 0, kind: .notice(.goalChangedSinceApproval)))
        }
        return (items, first == nil ? nil : seq - 1)
    }

    /// The step a person or the run is at, taken from the spine; never a second rule.
    private static func next(spine: ThreadSpine, state: ThreadState, attention: Attention, lastSeq: Int) -> FeedItem {
        // What can be done now comes before what already failed: after a failed turn Review is the step, not the Run that failed.
        // A thread that was discarded or cleaned has nothing left to do, and a failed run in its past is not a step.
        let finished = state.decision == "discarded" || state.cleaned
        let marks: [SpineMark] = finished ? [.needsYou, .current] : [.needsYou, .current, .failed]
        let open = marks.lazy.compactMap { mark in spine.entries.first { $0.mark == mark } }.first
        var why = open?.sublabel ?? ""
        if case .needsYou(let reason) = attention { why = reason.text }
        if why.isEmpty { why = open.map { $0.step.title } ?? "Nothing is left to do." }
        let text = ThreadState.safeLine(why, limit: summaryLimit)
        return FeedItem(id: "next", seq: lastSeq, turn: 0, kind: .next(step: open?.step, why: text))
    }

    private static func bounded(_ items: [FeedItem], room: Int) -> [FeedItem] {
        guard items.count > room else { return items }
        // Keep the newest; one notice says how many earlier ones are not shown.
        let keep = room - 1
        var out = Array(items.suffix(keep))
        out.insert(FeedItem(id: "earlier", seq: 0, turn: 0, kind: .notice(.earlierNotShown(count: items.count - keep))), at: 0)
        return out
    }
}
