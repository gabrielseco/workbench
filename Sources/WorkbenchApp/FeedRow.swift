import SwiftUI
import WorkbenchCore

/// One row of the feed. Colour keeps its five meanings and every row also says it in words or a symbol: blue working, green done,
/// amber needs you, red broken, grey idle.
struct FeedRow: View {
    var item: FeedItem
    /// The goal, for the goal card: the log keeps only how many criteria there are, not what they say.
    var goal: GoalModel?
    var store: ProjectStore?
    /// The goal may be changed now: its card is the editor.
    var editable: Bool
    /// What the draft goal card needs of the thread: its footer holds the decision's actions.
    var draft: DraftGoalContext?
    /// The conversation a goal made from a chat came from: its fold stays above the goal card in every state.
    var brainstorm: [ChatMessage] = []
    /// What the latest finished turn says beside "Run finished", and the screenshots under the latest "Verify passed".
    var finish: FinishContext?
    var shots: [ProofShot] = []

    init(
        item: FeedItem, goal: GoalModel? = nil, store: ProjectStore? = nil, editable: Bool = false,
        draft: DraftGoalContext? = nil, brainstorm: [ChatMessage] = [], finish: FinishContext? = nil, shots: [ProofShot] = []
    ) {
        (self.item, self.goal, self.store, self.editable, self.draft) = (item, goal, store, editable, draft)
        (self.brainstorm, self.finish, self.shots) = (brainstorm, finish, shots)
    }

    var body: some View {
        switch item.kind {
        case .userNote(let text): UserNoteRow(text: text)
        case .goalCard(let title, let approval, let count, let hash):
            GoalCardRow(
                title: title, approval: approval, criteria: count, hash: hash, goal: goal, store: store, editable: editable,
                draft: draft, brainstorm: brainstorm)
        case .turn(let number, let phase, let durationMs, let cost):
            TurnRow(number: number, phase: phase, durationMs: durationMs, cost: cost, finish: finish)
        case .agentText(let text):
            Text(text).textStyle(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .toolGroup(let count, let summaries): ToolGroupRow(count: count, summaries: summaries)
        case .edit(let file, let tool):
            FeedLine(symbol: "pencil", tint: Theme.grey, title: tool, detail: file, mono: true, inline: true)
        case .denied(let tool, let input):
            FeedLine(
                symbol: "hand.raised.fill", tint: Theme.amber, title: "Refused \(tool)", detail: input, mono: true, inline: true)
        case .check(let result, let command, let durationMs): CheckRow(result: result, command: command, durationMs: durationMs)
        case .judge(let ok, let criteria, let unmet, let concerns):
            JudgeRow(ok: ok, criteria: criteria, unmet: unmet, concerns: concerns)
        case .verify(let ok, let reason, let proofs): VerifyRow(ok: ok, reason: reason, proofs: proofs, shots: shots)
        case .plan(let tasks): PlanRow(tasks: tasks)
        case .decision(let text):
            FeedLine(["accepted", "succeeded"].contains(text) ? .passed : .stopped, title: text.capitalized)
        case .pullRequest(let number, let url):
            FeedLine(
                symbol: "arrow.up.right.circle.fill", tint: Theme.green,
                title: number.map { "Shipped as PR #\($0)" } ?? "Shipped", detail: url, inline: true, link: true)
        case .prReview(let round, let verdict, let ok): PRReviewRow(round: round, verdict: verdict, ok: ok)
        case .next(let step, let why): NextCard(step: step, why: why)
        case .notice(let notice): NoticeRow(notice: notice)
        }
    }
}

/// A symbol, a line of words and, beneath, the detail it is about: the shape of most rows.
struct FeedLine: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String?
    var mono = false
    /// The detail follows the title on one line (a file, a command) instead of sitting under it (a sentence of explanation).
    var inline = false
    /// The detail is an address: a click opens it instead of only selecting it.
    var link = false

    var body: some View {
        IconRow(symbol: symbol, tint: tint) {
            if inline {
                Text(title).textStyle(.callout, .primary).lineLimit(1).layoutPriority(1)
                if let detail, !detail.isEmpty { detailText(detail).lineLimit(3) }
            } else {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).textStyle(.callout, .primary)
                    if let detail, !detail.isEmpty { detailText(detail).lineLimit(2) }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func detailText(_ detail: String) -> some View {
        if link, let url = URL(string: detail), ["https", "http"].contains(url.scheme?.lowercased()) {
            Link(destination: url) { Text(detail).textStyle(.callout, .blue).truncationMode(.middle) }.buttonStyle(.link)
                .help("Opens it in your browser")
        } else { plainDetail(detail) }
    }

    private func plainDetail(_ detail: String) -> some View {
        Text(detail).textStyle(mono ? .monoCallout : .callout, .secondary)
            .truncationMode(.middle).textSelection(.enabled)
    }
}

struct UserNoteRow: View {
    var text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("You · sent back").role(.caption)
                Text(text).textStyle(.body).textSelection(.enabled)
            }
            .padding(Space.m).background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.quiet))
        }
    }
}

/// What the draft goal card takes from the thread it is in: the snapshot (the base, the chat behind it), the decision whose actions its
/// footer holds, and what they do.
struct DraftGoalContext {
    var snapshot: ThreadSnapshot
    var decision: FeedDecision
    var perform: (FeedAction) -> Void
}

struct GoalCardRow: View {
    var title: String?
    var approval: ApprovalState?
    var criteria: Int
    var hash: String?
    var goal: GoalModel?
    var store: ProjectStore?
    var editable = false
    var draft: DraftGoalContext?
    var brainstorm: [ChatMessage] = []
    @State private var showAllRequest = false
    /// A read-only request this long is folded, as on the Goal screen.
    static let foldedRequest = 500
    /// Criteria shown on the summary; a longer list is the editor's to show whole.
    static let shownCriteria = 6

    private var rows: [GoalModel.Row] { goal?.rows ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            // The conversation a goal made from a chat came from stays to read, whatever has become of the goal.
            if !brainstorm.isEmpty { BrainstormFoldView(messages: brainstorm) }
            if editable, let goal, let store { editor(goal, store) } else { summary }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("GOAL")
            Text(title ?? "Goal").textStyle(.heading).lineLimit(2)
            HStack(spacing: Space.m) {
                Label(approvalText, systemImage: approvalSymbol).foregroundStyle(approvalTint)
                Text("\(criteria) \(criteria == 1 ? "criterion" : "criteria")").foregroundStyle(.secondary)
                if let hash, !hash.isEmpty {
                    Text(String(hash.prefix(7))).role(.monoDetail)
                }
            }
            .textStyle(.callout)
        }
        .accessibilityElement(children: .combine)
    }

    /// A draft goal: the card is the editor, the Goal screen's blocks changed in place.
    @ViewBuilder private func editor(_ goal: GoalModel, _ store: ProjectStore) -> some View {
        if let draft {
            VStack(alignment: .leading, spacing: Space.l) {
                if !brainstorm.isEmpty { AgentLineView(text: BrainstormFold.agentLine) }
                DraftGoalCardView(
                    goal: goal, store: store, base: draft.snapshot.base, decision: draft.decision, perform: draft.perform)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: Space.l) {
                heading
                GoalBlocks(goal: goal, store: store, editable: true, showsError: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            heading
            // Why approval is blocked is said whether or not the goal can be edited: a goal that does not parse has no editor.
            if let blockers = goal?.blockers, !blockers.isEmpty {
                ForEach(blockers, id: \.self) { Message(.error, $0) }
            }
            if let request = goal?.request, !request.isEmpty { requestText(request) }
            if !rows.isEmpty { criteriaList }
        }
        .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .callout()
    }

    /// What was asked, so a goal with no criteria still says what it is for; a long one is folded.
    private func requestText(_ request: String) -> some View {
        let long = request.count > Self.foldedRequest
        return VStack(alignment: .leading, spacing: Space.xs) {
            Text(request).textStyle(.callout).textSelection(.enabled).lineLimit(long && !showAllRequest ? 6 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            if long {
                Button(showAllRequest ? "Show less" : "Show more") { showAllRequest.toggle() }
                    .buttonStyle(.borderless).textStyle(.callout)
            }
        }
        .padding(.top, Space.xxs)
    }

    /// What approving means: each criterion and the proof that will check it, and why a proof cannot be checked when it cannot.
    private var criteriaList: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(rows.prefix(Self.shownCriteria)), id: \.id) { row in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(row.id).role(.mono)
                        .frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(row.text).textStyle(.callout).textSelection(.enabled)
                        Text(row.proof).role(.mono)
                            .lineLimit(1).truncationMode(.middle)
                        if let warning = row.warning { Text(warning).textStyle(.caption, .amber) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if rows.count > Self.shownCriteria {
                Text("and \(rows.count - Self.shownCriteria) more").role(.caption)
            }
        }
        .padding(.top, Space.xs)
    }

    private var approvalText: String {
        switch approval {
        case .approved?: "Approved"
        case .draft?: "Draft · not approved"
        case .stale?: "Changed since approval"
        case nil: "unknown"
        }
    }

    /// The approval as a mark: approved is done, a goal changed since is amber, and a draft is the quiet ring.
    private var approvalSymbol: String {
        switch approval {
        case .approved?: Outcome.passed.symbol
        case .stale?: Outcome.warning.symbol
        default: "circle"
        }
    }

    private var approvalTint: Color {
        switch approval {
        case .approved?: Outcome.passed.tint
        case .stale?: Outcome.warning.tint
        default: Theme.grey
        }
    }
}

struct TurnRow: View {
    var number: Int
    var phase: FeedItem.Phase
    var durationMs: Int?
    var cost: Double?
    var finish: FinishContext?

    var body: some View {
        HStack(spacing: Space.s) {
            switch phase {
            case .working: Spinner(inColumn: true)
            default: StatusMark(outcome).frame(width: 16)
            }
            Text(title).textStyle(.calloutStrong)
            if let detail { Text(detail).role(.detail) }
            Spacer(minLength: 0)
        }
        .padding(.top, Space.s)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch phase {
        case .working: "Turn \(number) · working"
        case .orphaned: "Turn \(number) · the runner is gone"
        case .unrecorded: "Turn \(number) · how it ended is not recorded"
        case .ended(let result):
            switch result {
            case "succeeded": finish == nil ? "Turn \(number) ended" : "Run finished"
            case "timed_out": "Turn \(number) timed out"
            case "budget_exceeded": "Turn \(number) went over budget"
            default: "Turn \(number) \(result.replacingOccurrences(of: "_", with: " "))"
            }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let finish, case .ended(let result) = phase, result == "succeeded" {
            if let tasks = finish.tasks { parts.append("\(tasks) \(tasks == 1 ? "task" : "tasks")") }
            if let totals = finish.totals { parts.append(totals) }
        }
        if let durationMs { parts.append(Self.duration(durationMs)) }
        if let cost { parts.append(String(format: "$%.2f", cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var outcome: Outcome {
        switch phase {
        case .working: .pending
        case .ended("succeeded"): .passed
        case .ended("stopped"): .stopped
        case .unrecorded: .unknown
        case .orphaned: .warning
        default: .failed
        }
    }

    static func duration(_ ms: Int) -> String {
        let seconds = ms / 1000
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

struct ToolGroupRow: View {
    var count: Int
    var summaries: [String]

    var body: some View {
        IconRow(symbol: "wrench.and.screwdriver", tint: Theme.grey) {
            Text("\(count) tool \(count == 1 ? "call" : "calls")").textStyle(.callout)
            Text(summaries.joined(separator: " · ") + (count > summaries.count ? " …" : ""))
                .role(.monoDetail).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CheckRow: View {
    var result: String
    var command: String?
    var durationMs: Int?

    var body: some View {
        let passed = result == "passed"
        FeedLine(
            passed ? .passed : .failed,
            title: "Check \(result.replacingOccurrences(of: "_", with: " "))"
                + (durationMs.map { " · " + TurnRow.duration($0) } ?? ""),
            detail: command, mono: true, inline: true)
    }
}

struct JudgeRow: View {
    var ok: Bool
    var criteria: Int
    var unmet: Int
    var concerns: Int

    var body: some View {
        if !ok {
            FeedLine(.unknown, title: "The judge did not answer")
        } else if unmet == 0 {
            FeedLine(
                .passed,
                title: "Judge agrees · \(criteria) of \(criteria) criteria met", detail: concernText)
        } else {
            FeedLine(
                .warning,
                title: "Judge: \(criteria - unmet) of \(criteria) criteria met", detail: concernText)
        }
    }

    private var concernText: String? { concerns > 0 ? "\(concerns) \(concerns == 1 ? "concern" : "concerns")" : nil }
}

struct VerifyRow: View {
    var ok: Bool
    var reason: String?
    var proofs: [String]
    var shots: [ProofShot] = []
    @Environment(\.openScreenshotPreview) private var openPreview

    var body: some View {
        if ok, !shots.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                FeedLine(.passed, title: "Verify passed")
                HStack(alignment: .top, spacing: Space.m) {
                    ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                        ProofThumbnail(shot: shot) { openPreview(.proof(shots, at: index)) }
                    }
                }
            }
            .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else {
            line
        }
    }

    private var line: some View {
        FeedLine(
            ok ? .passed : .failed,
            title: ok ? "Verify passed" : "Verify failed" + (reason.map { ": \($0)" } ?? ""),
            detail: proofs.isEmpty ? nil : proofs.joined(separator: ", "))
    }
}

struct PRReviewRow: View {
    var round: Int?
    var verdict: String?
    var ok: Bool

    static func outcome(ok: Bool, verdict: String?) -> String {
        if !ok { return "did not finish" }
        guard let verdict else { return "no verdict" }
        return verdict == "clean" ? "clean" : "findings to fix"
    }

    var body: some View {
        let clean = ok && verdict == "clean"
        // The step screen's words for it: the core's verdict is "clean" or a list of findings.
        let outcome = Self.outcome(ok: ok, verdict: verdict)
        FeedLine(
            clean ? .passed : (ok ? .warning : .failed),
            title: "PR review" + (round.map { " round \($0)" } ?? "") + " · " + outcome, detail: nil)
    }
}

/// The one next step and why, from the spine and attention. It is a statement, not a button: the buttons stay on the step screens.
struct NextCard: View {
    var step: SpineStep?
    var why: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel("NEXT")
            Text(step?.title ?? "Nothing left to do").textStyle(.heading)
            Text(why).role(.detail)
        }
        .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .callout(.outlined)
        .padding(.top, Space.s)
        .accessibilityElement(children: .combine)
    }
}

struct NoticeRow: View {
    var notice: FeedItem.Notice

    var body: some View {
        switch notice {
        case .activityNotStored(let count):
            FeedLine(symbol: "ellipsis.circle", tint: Theme.grey, title: "\(count) activity items were not stored", detail: nil)
        case .activityFolded(let count, let refusals):
            FeedLine(
                symbol: "ellipsis.circle", tint: Theme.grey, title: "\(count) more items in this turn are folded",
                detail: (refusals > 0 ? "\(refusals) of them refused calls. " : "") + "Open the event log to see them.")
        case .logDamaged(let problems, let first):
            FeedLine(
                .failed,
                title: "The log has \(problems) damaged \(problems == 1 ? "line" : "lines"); this shows what could be read.",
                detail: first + ". Open the event log to see it; Workbench never rewrites it.")
        case .logTailCut:
            FeedLine(
                symbol: "scissors", tint: Theme.grey, title: "The last line of the log was cut short, as a crash leaves it",
                detail: nil)
        case .goalChangedSinceApproval:
            FeedLine(
                .warning, title: "The goal changed since it was approved",
                detail: "Approve it again before it runs.")
        case .earlierNotShown(let count):
            FeedLine(
                symbol: "ellipsis.circle", tint: Theme.grey, title: "\(count) earlier items are not shown",
                detail: "Open the event log to see them.")
        }
    }
}
