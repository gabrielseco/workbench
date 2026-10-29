import Foundation
import WorkbenchCore

/// Accept and Discard: what core says each would do is fetched and shown first, and only what was shown is done.
extension ProjectStore {
    func prepareAccept() async {
        guard let project, let thread = currentThread, !deciding else { return }
        actionError = nil
        notice = nil
        let mine = generation
        await working("Checking what Accept would do…") {
            do {
                let plan = try await actions.acceptPlan(project, thread)
                if mine == generation { pendingAccept = plan }
            } catch { if mine == generation { actionError = "\(error)" } }
        }
    }

    /// Accepts what was shown: core refuses it when the work changed since, and nothing is committed then.
    func confirmAccept(message: String?) async {
        guard let project, let thread = currentThread, let plan = pendingAccept, !deciding else { return }
        deciding = true
        defer { deciding = false }
        pendingAccept = nil
        await working("Accepting: committing the work…") {
            do {
                let result = try await actions.accept(project, thread, plan, message)
                notice = "Accepted: \(result.commit.prefix(7)) on \(result.branch)"
            } catch { actionError = "\(error)" }
            await reload()
        }
    }

    /// Reads the review again: the worktree and the branch are not in the log, so an edit there is seen on activation or here.
    func refreshReview() async {
        guard let project, let thread = currentThread, review != nil else { return }
        let (mine, load) = (generation, actions.loadReview)
        let report = await Task.detached { await load(project, thread) }.value
        guard mine == generation, review != nil else { return }
        review = report.map(ReviewModel.derive)
    }

    func cancelAccept() { pendingAccept = nil }

    func prepareDiscard() async {
        guard let project, let thread = currentThread, !deciding else { return }
        actionError = nil
        notice = nil
        let mine = generation
        await working("Checking what Discard would remove…") {
            do {
                let plan = try await actions.discardPlan(project, thread)
                if mine == generation { pendingDiscard = plan }
            } catch { if mine == generation { actionError = "\(error)" } }
        }
    }

    func confirmDiscard() async {
        guard let project, let thread = currentThread, let plan = pendingDiscard, !deciding else { return }
        deciding = true
        defer { deciding = false }
        pendingDiscard = nil
        await working("Discarding: removing the worktree and branch…") {
            do { try await actions.discard(project, thread, plan) } catch { actionError = "\(error)" }
            await reload()
        }
    }

    func cancelDiscard() { pendingDiscard = nil }
}
