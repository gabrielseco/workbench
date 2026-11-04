import SwiftUI
import WorkbenchCore

/// What the draft goal card says, derived from the goal (design parity 7). Pure, so each line is tested without a window.
enum DraftGoalCard {
    struct Header: Equatable {
        var pill: String
        var tone: TaskTone
        /// `Every field is editable`, only while the card is the editor.
        var hint: String?
    }

    static func header(goal: GoalModel, editable: Bool) -> Header {
        let hint = editable ? "Every field is editable" : nil
        switch goal.pill {
        // Approve is off for a blocker, a placeholder left in the file and a proof Workbench cannot check: the pill says so for all three.
        case .draft where !goal.canApprove: return Header(pill: "Can't approve yet", tone: .broken, hint: hint)
        case .draft: return Header(pill: "Needs approval", tone: .needsYou, hint: hint)
        case .approved: return Header(pill: "Approved", tone: .done, hint: hint)
        case .changedSinceApproval: return Header(pill: "Changed since approval", tone: .needsYou, hint: hint)
        }
    }

    /// What Approve starts, in a line: the worktree's base and whether the verifier and the judge will run on it.
    static func footer(goal: GoalModel, base: String?) -> String {
        func state(_ name: String) -> Bool? {
            goal.steps.first { $0.name == name }.map { !$0.skipped && $0.unavailable == nil }
        }
        let from = base.map { "a worktree from \($0)" } ?? "a worktree"
        let on = [("Verifier", state("verifier")), ("Judge", state("judge"))].compactMap { name, on in on.map { (name, $0) } }
        guard !on.isEmpty else { return "Starts \(from)." }
        let enabled = on.filter(\.1).map(\.0)
        let disabled = on.filter { !$0.1 }.map(\.0)
        var parts: [String] = []
        if !enabled.isEmpty { parts.append(enabled.joined(separator: " and ") + " on") }
        if !disabled.isEmpty { parts.append(disabled.joined(separator: " and ") + " off") }
        return "Starts \(from) with \(parts.joined(separator: ", "))."
    }

    /// The *Next* card is the card's own footer for an editable draft goal; every other state keeps it.
    static func hidesDecisionCard(editable: Bool) -> Bool { editable }
}

/// A goal that began as a chat has the conversation behind it: a fold that opens to it, and the agent's line about the draft.
enum BrainstormFold {
    static func title(count: Int) -> String { "Brainstorm · \(count) message\(count == 1 ? "" : "s")" }

    /// Shown for a thread that began as a chat and has messages, whatever has become of the goal since (the conversation is there to read
    /// again); a goal that began as a goal has none. The agent's line is only for a draft that can still be edited.
    static func shown(state: ThreadState) -> Bool { state.isChat && !(state.chat?.messages.isEmpty ?? true) }

    static let agentLine = "I drafted a goal from this chat. Edit anything below, then approve. Nothing runs until you do."
}

struct BrainstormFoldView: View {
    var messages: [ChatMessage]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").textStyle(.captionStrong)
                    Text(BrainstormFold.title(count: messages.count)).textStyle(.callout)
                }
                .foregroundStyle(.secondary).pill(style: .outlined, size: .regular)
            }
            .buttonStyle(.plain).accessibilityLabel(BrainstormFold.title(count: messages.count))
            .accessibilityValue(open ? "open" : "closed")
            if open { ForEach(messages, id: \.seq) { ChatMessageRow(message: $0) } }
        }
    }
}

/// The agent's line about the draft, with its avatar, as a chat message is drawn.
struct AgentLineView: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "sparkle").textStyle(.captionMedium, .secondary).frame(width: 22, height: 22)
                .background(Theme.raised, in: Circle()).overlay(Circle().stroke(Theme.line)).padding(.top, Space.xxs)
            Text(text).textStyle(.body).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The *Draft goal* card (the artboard's B): its state, the blocks, and one footer with what Approve starts and the actions.
struct DraftGoalCardView: View {
    var goal: GoalModel
    var store: ProjectStore
    var base: String?
    var decision: FeedDecision
    var perform: (FeedAction) -> Void

    private var header: DraftGoalCard.Header { DraftGoalCard.header(goal: goal, editable: true) }

    private var tint: Color {
        switch header.tone {
        case .done: Theme.green
        case .broken: Theme.red
        default: Theme.amber
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                SectionLabel("DRAFT GOAL")
                Text(header.pill).pill(tint)
                Spacer(minLength: 8)
                if let hint = header.hint { Text(hint).role(.caption) }
            }
            .padding(.horizontal, Spacing.inset).padding(.vertical, Space.m)
            Divider()
            GoalBlocks(goal: goal, store: store, editable: true, style: .feed, showsError: true).padding(Spacing.inset)
            Divider()
            HStack(spacing: Space.m) {
                Text(DraftGoalCard.footer(goal: goal, base: base)).role(.caption)
                Spacer(minLength: 8)
                DecisionActions(decision: decision, perform: perform)
            }
            .padding(.horizontal, Spacing.inset).padding(.vertical, Space.m)
        }
        .card()
    }
}
