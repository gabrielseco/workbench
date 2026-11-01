import SwiftUI
import WorkbenchCore

/// Shows what a task will do with nobody watching, and records the approval only when it is confirmed. Esc and Cancel close it;
/// ⌘Return confirms. A refusal stays in the card, in the core's words.
struct TaskApproveCard: View {
    var store: ProjectStore
    var card: TaskCardInfo
    var stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Approve task".uppercased()).font(.caption2.weight(.semibold)).tracking(0.9).foregroundStyle(.secondary)
                Spacer()
                Button { store.tasks.cancelApprove() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close without approving")
                    .accessibilityLabel("Close the approve panel")
            }
            Text(card.name).font(.title2.weight(.semibold)).padding(.top, 8)
            Text(
                "Approving lets this run unattended, on its schedule, with nobody watching. It is bound to what is shown here: "
                    + "editing any of it takes the approval back."
            )
            .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            if stale {
                Label("Edited since it was last approved.", systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(Theme.amber).padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(card.settings, id: \.label) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Text(line.value).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 12)
            Text("INSTRUCTIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 12)
            ScrollView {
                Text(card.instructions).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 150).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if let error = store.tasks.approveError {
                Text(error).font(.callout).foregroundStyle(Theme.red).textSelection(.enabled).padding(.top, 10)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.tasks.cancelApprove() }.keyboardShortcut(.cancelAction)
                Button("Approve") { Task { await store.tasks.confirmApprove(store.project) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.top, 16)
        }
        .overlayCard()
        .onExitCommand { store.tasks.cancelApprove() }
    }
}

/// Asks before a `fix: pr` run, which spends money and opens a pull request.
struct TaskRunCard: View {
    var store: ProjectStore
    var card: TaskCardInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Run now".uppercased()).font(.caption2.weight(.semibold)).tracking(0.9).foregroundStyle(.secondary)
            Text(card.name).font(.title2.weight(.semibold)).padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text("It starts a coding turn, and when the check passes it opens a pull request. Nothing merges.")
                Text("It may cost \(card.cost).").monospacedDigit()
                Text("Quitting the app while it runs ends the run as interrupted. Stop ends the turn and records how.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout).padding(.top, 8)
            HStack {
                Spacer()
                Button("Cancel") { store.tasks.cancelRun() }.keyboardShortcut(.cancelAction)
                Button("Run now") { Task { await store.tasks.confirmRun(store.project) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.top, 16)
        }
        .overlayCard()
        .onExitCommand { store.tasks.cancelRun() }
    }
}
