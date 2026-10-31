import SwiftUI
import WorkbenchCore

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
            if let error = store.followUpError { Text(error).font(.callout).foregroundStyle(Theme.red) }
            HStack {
                // The sheet covers the window's own busy line, so a click on "Fix these findings" shows here that it was taken.
                if let busy = store.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let shown = store.prReviewShown, shown.canFix {
                    Button("Fix these findings") { Task { await store.fixFindings() } }.disabled(store.busy != nil)
                }
                Button("Close") { store.closePRReview() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 680)
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
