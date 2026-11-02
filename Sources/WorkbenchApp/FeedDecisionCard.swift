import SwiftUI
import WorkbenchCore

/// The last row of the feed: where the thread is, why, and the one button that moves it on, with the rest in a menu. It says nothing of
/// its own: `decision` comes from `FeedActions.derive` and every button runs the action the step screen's button runs.
struct DecisionCard: View {
    var step: SpineStep?
    var why: String
    var decision: FeedDecision
    var perform: (FeedAction) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(step?.title ?? "Nothing left to do").font(.headline)
                Text(why).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if !decision.more.isEmpty {
                Menu {
                    ForEach(decision.more) { action in
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
            if let primary = decision.primary {
                Button(primary.title) { perform(primary) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!primary.enabled)
                    .help(primary.help ?? primary.title)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.grey.opacity(0.4)))
        .padding(.top, 6)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
