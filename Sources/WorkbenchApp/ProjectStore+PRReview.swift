import Foundation
import WorkbenchCore

/// PR review from the window: Codex reads the shipped thread's pull request, read-only, and what it found is shown.
extension ProjectStore {
    func reviewPullRequest() async {
        guard let project, let thread = currentThread, !deciding else { return }
        actionError = nil
        notice = nil
        let mine = generation
        await working("Reviewing the pull request with Codex: this takes a few minutes…") {
            do {
                let shown = try await actions.prReview(project, thread)
                if mine == generation { prReviewShown = shown }
            } catch { if mine == generation { actionError = "\(error)" } }
            if mine == generation { await reload() }
        }
    }

    /// Opens what the latest round found, for a review that was run before (here or from a terminal).
    func showPRReview() async {
        guard let project, let thread = currentThread else { return }
        actionError = nil
        let mine = generation
        let load = actions.latestPRReview
        let shown = await Task.detached { await load(project, thread) }.value
        guard mine == generation else { return }
        if let shown { prReviewShown = shown } else { actionError = "No pull request review has run for this thread yet." }
    }

    func closePRReview() { prReviewShown = nil }
}
