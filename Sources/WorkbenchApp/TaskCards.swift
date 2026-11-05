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
                Text("Approve task".uppercased()).textStyle(.captionStrong).tracking(0.9).foregroundStyle(.secondary)
                Spacer()
                Button { store.tasks.cancelApprove() } label: { Image(systemName: "xmark").textStyle(.captionStrong) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close without approving")
                    .accessibilityLabel("Close the approve panel")
            }
            Text(card.name).textStyle(.title).padding(.top, Space.s)
            Text(
                "Approving lets this run unattended, on its schedule, with nobody watching. It is bound to what is shown here: "
                    + "editing any of it takes the approval back."
            )
            .role(.detail).padding(.top, Space.xs)
            if stale {
                Label("Edited since it was last approved.", systemImage: "exclamationmark.circle.fill")
                    .textRole(.warning).padding(.top, Space.s)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(card.settings, id: \.label) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(line.label).role(.caption).frame(width: 70, alignment: .leading)
                        Text(line.value).textStyle(.callout).textSelection(.enabled)
                    }
                }
            }
            .padding(.top, Space.m)
            SectionLabel("INSTRUCTIONS").padding(.top, Space.m)
            ScrollView {
                Text(card.instructions).textStyle(.monoCallout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Space.s)
            }
            .frame(height: 150).callout(.neutral)
            if let error = store.tasks.approveError {
                Text(error).role(.error).textSelection(.enabled).padding(.top, Space.m)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.tasks.cancelApprove() }.plainButton(size: .regular).keyboardShortcut(.cancelAction)
                Button("Approve") { Task { await store.tasks.confirmApprove(store.project) } }
                    .primaryButton().keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.top, Space.l)
        }
        .overlayCard()
        .onExitCommand { store.tasks.cancelApprove() }
    }
}
