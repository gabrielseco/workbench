import Foundation
import WorkbenchCore

/// Accept runs on the click, with the default commit message. Discard fetches what core says it would remove and shows it first,
/// and only what was shown is done.
extension ProjectStore {
    /// Reads core's plan and accepts it at once: core refuses it when the work changed in between, and nothing is committed then.
    func accept() async {
        guard let project, let thread = currentThread, !deciding, busy == nil else { return }
        // Set before the first await, so a second click while this one is going starts nothing.
        deciding = true
        defer { deciding = false }
        actionError = nil
        notice = nil
        let mine = generation
        await working("Checking what Accept would do…") {
            do {
                let plan = try await actions.acceptPlan(project, thread)
                guard mine == generation else { return }
                nowWorking("Accepting: committing the work…")
                let result = try await actions.accept(project, thread, plan, nil)
                if mine == generation { notice = "Accepted: \(result.commit.prefix(7)) on \(result.branch)" }
            } catch { if mine == generation { actionError = "\(error)" } }
            if mine == generation { await reload() }
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
