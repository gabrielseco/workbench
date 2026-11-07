import SwiftUI
import WorkbenchCore

/// What Codex found in the pull request: the verdict, then its words as written.
struct PRReviewBody: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let shown = store.prReviewShown {
                Label(shown.headline, systemImage: icon(shown)).textStyle(.heading).foregroundStyle(color(shown))
                ForEach(shown.notes, id: \.self) { Text($0).role(.warning) }
                ScrollView {
                    Text(shown.findings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Codex wrote nothing.")
                        .textStyle(.monoCallout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 320)
                Text(
                    "A review reads the code and cannot run tests, so CI has to be green as well. "
                        + "Nothing was posted to the pull request."
                )
                    .role(.detail)
            }
            if let error = store.followUpError { Text(error).role(.error) }
            ModalFooter {
                // The modal covers the window's own busy line, so a click on "Fix these findings" shows here that it was taken.
                if let busy = store.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).role(.detail)
                }
            } actions: {
                if let shown = store.prReviewShown, shown.canFix {
                    Button("Fix these findings") { Task { await store.fixFindings() } }.plainButton(size: .regular)
                        .disabled(store.busy != nil)
                }
                Button("Close") { store.closePRReview() }.keyboardShortcut(.defaultAction).primaryButton(size: .regular)
            }
        }
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

/// The question before the pull request is merged: what the merge does, and the yes.
struct MergeBody: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Squash-merges it on GitHub at the commit whose checks are green. This cannot be undone from Workbench.")
                .role(.detail).fixedSize(horizontal: false, vertical: true)
            ModalFooter {
                Button("Cancel") { store.feedModals.confirmingMerge = false }.plainButton(size: .regular)
                Button("Merge") {
                    store.feedModals.confirmingMerge = false
                    Task { await store.mergePullRequest() }
                }
                .primaryButton(size: .regular)
            }
        }
    }
}
