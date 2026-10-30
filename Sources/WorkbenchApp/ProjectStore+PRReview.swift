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

    func closePRReview() { (prReviewShown, pendingFollowUp, followUpError) = (nil, nil, nil) }

    /// Reads what a fix round would start, to show it before anything is made.
    func prepareFollowUp() async {
        guard let project, let thread = currentThread, let shown = prReviewShown, shown.canFix else { return }
        followUpError = nil
        let mine = generation
        do {
            let plan = try await actions.followUpPlan(project, thread, shown.pr)
            if mine == generation { pendingFollowUp = plan }
        } catch { if mine == generation { followUpError = "\(error)" } }
    }

    func cancelFollowUp() { (pendingFollowUp, followUpError) = (nil, nil) }

    /// Starts core's follow-up from the round shown, then shows it and runs its first turn. A refusal stays in the sheet and
    /// starts nothing.
    func confirmFollowUp() async {
        guard let project, let thread = currentThread, let shown = prReviewShown, shown.canFix,
            let plan = pendingFollowUp, plan.refusal == nil, !starting
        else { return }
        followUpError = nil
        let mine = generation
        var made: String?
        await working("Starting the fix round…") {
            do { made = try await actions.startFollowUp(project, thread, shown.findings ?? "", shown.round) } catch {
                if mine == generation { followUpError = "\(error)" }
            }
        }
        guard let id = made, mine == generation else { return }
        closePRReview()
        await reload()
        guard mine == generation else { return }
        startRun(project, id, generation: mine)
    }
}
