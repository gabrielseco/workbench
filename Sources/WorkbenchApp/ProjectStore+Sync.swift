import Foundation
import WorkbenchCore

extension ProjectStore {
    /// `Bring up to date` on the review: fetch the base and merge it into the thread's branch, then start a turn from what the merge
    /// found (a clean merge: check the work still fits; a conflict: resolve it), exactly as `workbench sync --run` does. Core refuses
    /// what it cannot do (a run holds the thread, the worktree is on another branch) in its own words.
    func bringBaseIn() async {
        guard let project, let thread = currentThread, !starting, !runningHere else { return }
        actionError = nil
        let mine = generation
        var found: BaseSyncResult?
        await working("Bringing the base in…") {
            do { found = try await actions.syncBase(project, thread) } catch { current.actionError = "\(error)" }
        }
        guard let found else { return }
        await refreshReview()
        guard mine == generation, let note = SyncPrompt.note(for: found) else {
            if case .upToDate = found { notice = "The base has not moved: there is nothing to bring in." }
            return
        }
        startRun(project, thread, generation: mine, options: RunOptions(feedback: note))
    }
}
