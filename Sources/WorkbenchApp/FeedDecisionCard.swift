import SwiftUI
import WorkbenchCore

/// The last row of the feed: where the thread is, why, and the one button that moves it on, with the rest in a menu. It says nothing of
/// its own: `decision` comes from `FeedActions.derive` and every button runs the action the step screen's button runs.
struct DecisionCard: View {
    var step: SpineStep?
    var why: String
    var decision: FeedDecision
    var perform: (FeedAction) -> Void
    /// `branch → base`, for the ready-to-ship bar's line.
    var route: String?

    /// The artboard's foot when the next press is Ship: the work is accepted and the person either ships it or asks for more.
    /// What the ship bar's `…` keeps: every other action of the decision, so Open worktree and New goal do not vanish; `Request changes`
    /// is its own button.
    static func shipMenu(_ decision: FeedDecision) -> [FeedAction] { decision.more.filter { $0.kind != .sendBack } }

    static func isReadyToShip(_ decision: FeedDecision) -> Bool { decision.primary?.kind == .ship }

    /// The decision's own line when it has one, else the spine's without the step name it repeats under the heading.
    private var shownWhy: String { Self.line(step: step, why: why, decision: decision) }

    static func line(step: SpineStep?, why: String, decision: FeedDecision) -> String {
        if let own = decision.why { return own }
        guard let title = step?.title, why.hasPrefix(title + " · ") else { return why }
        return String(why.dropFirst(title.count + 3))
    }

    var body: some View {
        if Self.isReadyToShip(decision) { readyToShip } else { next }
    }

    private var readyToShip: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready to ship").font(.headline)
                Text([route, "PR review comes back to this chat"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            MoreActionsMenu(actions: Self.shipMenu(decision), perform: perform)
            if let back = decision.more.first(where: { $0.kind == .sendBack }) {
                Button("Request changes") { perform(back) }
                    .plainButton(size: .regular).disabled(!back.enabled).help(back.help ?? back.title)
            }
            if let ship = decision.primary {
                Button(ship.title) { perform(ship) }.primaryButton().disabled(!ship.enabled)
                    .help(ship.help ?? ship.title)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(.top, 6)
    }

    private var next: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("NEXT")
                Text(decision.title ?? step?.title ?? "Nothing left to do").font(.headline)
                Text(shownWhy).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            DecisionActions(decision: decision, perform: perform)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .callout(.outlined)
        .padding(.top, 6)
    }
}

/// The decision's buttons: the `…` menu with the other actions and the one prominent button. The decision card and the draft goal card's
/// footer both draw these, so the same actions are disabled for the same reasons in both.
struct DecisionActions: View {
    var decision: FeedDecision
    var perform: (FeedAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            MoreActionsMenu(actions: decision.more, perform: perform)
            if let side = decision.secondary {
                Button(side.title) { perform(side) }
                    .plainButton(size: .regular)
                    .disabled(!side.enabled)
                    .help(side.help ?? side.title)
            }
            if let primary = decision.primary {
                Button(primary.title) { perform(primary) }
                    .primaryButton()
                    .disabled(!primary.enabled)
                    .help(primary.help ?? primary.title)
            }
        }
    }
}

/// The `…` menu with a decision's other actions; nothing when there are none.
struct MoreActionsMenu: View {
    var actions: [FeedAction]
    var perform: (FeedAction) -> Void

    var body: some View {
        if !actions.isEmpty {
            Menu {
                ForEach(actions) { action in
                    Button(role: action.destructive ? .destructive : nil) { perform(action) } label: { Text(action.title) }
                        .disabled(!action.enabled)
                        .help(action.help ?? action.title)
                }
            } label: {
                Label("More actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("More actions")
        }
    }
}

/// What the last action said, as rows at the foot of the feed: the same words the step screens show, from the thread's own session.
struct MessageRows: View {
    var error: String?
    var note: String?
    var notice: String?
    var handoff: HerdrHandoffOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error { MessageRow(symbol: "xmark.octagon.fill", tint: Theme.red, text: error) }
            if let note { MessageRow(symbol: "info.circle", tint: Theme.grey, text: note) }
            if let notice { MessageRow(symbol: "checkmark.circle.fill", tint: Theme.green, text: notice) }
            if let handoff {
                MessageRow(
                    symbol: handoff.isProblem ? "xmark.octagon.fill" : "checkmark.circle.fill",
                    tint: handoff.isProblem ? Theme.red : Theme.green, text: handoff.text)
            }
        }
    }
}

struct MessageRow: View {
    var symbol: String
    var tint: Color
    var text: String

    var body: some View {
        IconRow(symbol: symbol, tint: tint) {
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
