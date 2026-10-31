import Foundation
import WorkbenchCore

extension ProjectStore {
    /// "Open in Herdr": the thread's worktree as a Herdr space, brought forward. Herdr's own refusal is the error line.
    func openInHerdr() async {
        guard let project, let thread = currentThread else { return }
        (actionError, actionNote) = (nil, nil)
        let mine = generation
        await working("Opening in Herdr…") {
            do {
                let opened = try await actions.openInHerdr(project, thread)
                guard mine == generation else { return }
                actionNote = opened.alreadyOpen ? "Herdr already had it open: brought forward." : "Opened in Herdr."
            } catch { if mine == generation { actionError = "\(error)" } }
        }
    }
}
