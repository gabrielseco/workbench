import SwiftUI
import WorkbenchCore

/// Ship's confirmation: what will be pushed and the pull request's title and text, shown before anything leaves the machine.
struct ShipSheet: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ship this work").font(.headline)
            if let preview = store.pendingShip {
                Text(preview.pushLines.joined(separator: "\n")).font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let title = preview.title, let body = preview.body {
                    Text(title).font(.body.weight(.semibold))
                    ScrollView {
                        Text(body.trimmingCharacters(in: .newlines)).font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                } else {
                    Text("Pushes to the open pull request on \(preview.plan.remoteBranch); its title and text stay as they are.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let note = preview.note { Text(note).font(.callout).foregroundStyle(Theme.amber) }
                Text(
                    "It also puts the turn's screenshots in the pull request and removes the worktree "
                        + "when nothing could be lost. Workbench never merges for you."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.cancelShip() }
                Button("Push and open PR") { Task { await store.confirmShip() } }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 600)
    }
}

/// What Codex found in the pull request: the verdict, then its words as written.
struct PRReviewSheet: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let shown = store.prReviewShown {
                Label(shown.headline, systemImage: icon(shown)).font(.headline).foregroundStyle(color(shown))
                ForEach(shown.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(Theme.amber) }
                ScrollView {
                    Text(shown.findings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Codex wrote nothing.")
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 320)
                Text(
                    "A review reads the code and cannot run tests, so CI has to be green as well. "
                        + "Nothing was posted to the pull request."
                )
                    .font(.callout).foregroundStyle(.secondary)
            }
            fixRound
            HStack {
                Spacer()
                if let shown = store.prReviewShown, shown.canFix, store.pendingFollowUp == nil {
                    Button("Fix these findings…") { Task { await store.prepareFollowUp() } }.disabled(store.busy != nil)
                }
                Button("Close") { store.closePRReview() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 680)
    }

    /// The confirm before a fix round, and why one was refused.
    @ViewBuilder private var fixRound: some View {
        if let plan = store.pendingFollowUp {
            VStack(alignment: .leading, spacing: 6) {
                if let refusal = plan.refusal {
                    Text(refusal).font(.callout).foregroundStyle(Theme.amber)
                } else {
                    Text(plan.text).font(.callout)
                }
                HStack {
                    Button("Not now") { store.cancelFollowUp() }
                    if plan.refusal == nil {
                        Button("Start the fix round") { Task { await store.confirmFollowUp() } }
                            .buttonStyle(.borderedProminent).disabled(store.busy != nil)
                    }
                }
            }
        }
        if let error = store.followUpError { Text(error).font(.callout).foregroundStyle(Theme.red) }
    }

    private func icon(_ shown: PRReviewShown) -> String {
        shown.verdict == .clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func color(_ shown: PRReviewShown) -> Color {
        switch shown.verdict {
        case .clean?: Theme.green
        case .fix?: Theme.amber
        case nil: Theme.red
        }
    }
}
