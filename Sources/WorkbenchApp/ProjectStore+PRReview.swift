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

    func closePRReview() {
        followUpRequest += 1
        (prReviewShown, followUpError) = (nil, nil)
    }

    /// "Fix these findings": the click is the yes. Starts core's follow-up from the round shown, then shows it and runs its first
    /// turn. A refusal (no rounds left, no pull request on record) stays in the sheet and starts nothing; closing the sheet while
    /// the plan is read starts nothing either.
    func fixFindings() async {
        guard let project, let thread = currentThread, let shown = prReviewShown, shown.canFix, !starting else { return }
        followUpError = nil
        let mine = generation
        followUpRequest += 1
        let request = followUpRequest
        var made: String?
        await working("Starting the fix round…") {
            do {
                let plan = try await actions.followUpPlan(project, thread, shown.pr)
                guard mine == generation, request == followUpRequest else { return }
                if let refusal = plan.refusal {
                    followUpError = refusal
                    return
                }
                made = try await actions.startFollowUp(project, thread, shown.findings ?? "", shown.round, plan.budget)
            } catch {
                if mine == generation, request == followUpRequest { followUpError = "\(error)" }
            }
        }
        guard let id = made, mine == generation else { return }
        closePRReview()
        await reload()
        guard mine == generation else { return }
        fixRoundToShip = FixRound(thread: id, reviewRound: shown.round, generation: mine)
        startRun(project, id, generation: mine)
    }

    /// The rest of a fix round once its turn has ended, as `ship --review-loop --yes` does it: the click in the findings sheet
    /// was the yes, so the work is accepted, pushed to the same pull request and reviewed again without another click. Stops, and
    /// leaves the thread for the person, on a turn that did not succeed, a check that did not pass or a step that was refused.
    func continueFixRound(runFailed: Bool) async {
        guard let round = fixRoundToShip else { return }
        // Held until the round is done, so a reader can tell the window is still on it.
        defer { fixRoundToShip = nil }
        guard !runFailed else { return }
        await untilIdle()
        guard let project, round.generation == generation, currentThread == round.thread,
            case .thread(let shown) = screen
        else { return }
        let review = shown.state.review
        guard review.status == .awaitingReview, review.turnResult == RunResult.succeeded.rawValue else {
            notice = "The fix round's turn did not succeed (\(review.turnResult ?? "no result")), so nothing was pushed."
            return
        }
        let checkCommand = await Task.detached { (try? Config.load(from: project.configURL))?.checkCommand }.value
        guard round.generation == generation else { return }
        if checkCommand != nil || review.check != nil {
            let check = review.check.flatMap { $0.turn == shown.state.lastTurn ? $0.result : nil }
            guard check == "passed" else {
                notice = "The check did not pass after the fix round (\(check ?? "it did not run")), so nothing was pushed."
                return
            }
        }
        guard await accept(message: "fix: address review round \(round.reviewRound)"), round.generation == generation,
            currentThread == round.thread
        else { return }
        guard await ship(), round.generation == generation, currentThread == round.thread else { return }
        await reviewPullRequest()
    }
}

/// The fix round the app started from the findings sheet, and the review round whose findings it fixes.
struct FixRound: Equatable {
    var thread: String
    var reviewRound: Int
    var generation: Int
}
