import Foundation
import WorkbenchCore

extension ProjectStore {
    /// "Open in Herdr": the thread's worktree as a Herdr workspace, brought forward. Herdr's own refusal is the error line.
    func openInHerdr() async {
        guard let project, let thread = currentThread else { return }
        (actionError, actionNote) = (nil, nil)
        let mine = generation
        await working("Opening in Herdr…") {
            do {
                let opened = try await actions.openInHerdr(project, thread)
                guard mine == generation else { return }
                switch opened {
                case .worktree(_, let already):
                    actionNote = already ? "Herdr already had it open: brought forward." : "Opened in Herdr."
                case .folder(_, let already):
                    let how = already ? "brought forward" : "opened"
                    actionNote = "Herdr would not open it as a git worktree, so the folder is \(how) as a plain workspace."
                }
            } catch { if mine == generation { actionError = "\(error)" } }
        }
    }
}
