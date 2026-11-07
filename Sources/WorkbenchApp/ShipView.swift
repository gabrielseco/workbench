import SwiftUI
import WorkbenchCore

/// What Codex found in the pull request: the verdict, then its words as written.
struct PRReviewBody: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let shown = store.prReviewShown {
                Label(shown.headline, systemImage: outcome(shown).symbol).textStyle(.heading).foregroundStyle(outcome(shown).tint)
                ForEach(shown.notes, id: \.self) { Text($0).role(.warning) }
                ScrollView {
                    Text(shown.findings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Codex wrote nothing.")
                        .textStyle(.monoCallout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 280)
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

    /// A round that came out clean is done, one with findings needs the person, and one that did not finish failed.
    private func outcome(_ shown: PRReviewShown) -> Outcome {
        switch shown.verdict {
        case .clean?: .passed
        case .fix?: .warning
        case nil: .failed
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
                Button("Cancel") { store.modals.confirmingMerge = false }.plainButton(size: .regular)
                Button("Merge") {
                    store.modals.confirmingMerge = false
                    Task { await store.mergePullRequest() }
                }
                .primaryButton(size: .regular)
            }
        }
    }
}
