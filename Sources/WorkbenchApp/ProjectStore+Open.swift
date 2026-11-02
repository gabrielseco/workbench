import Foundation
import WorkbenchCore

extension ProjectStore {
    /// The diffs against the base in the editor: every changed file, or the one at `path`.
    func openDiff(path: String? = nil) async {
        guard let project, let thread = currentThread else { return }
        let session = current
        (session.actionError, session.actionNote) = (nil, nil)
        await working("Opening the diff…") {
            do {
                session.actionNote = try await actions.openDiff(project, thread, path)
            } catch { session.actionError = "\(error)" }
        }
    }

    func openGoalFile() async {
        guard let project, let thread = currentThread else { return }
        let session = current
        session.actionError = nil
        do { try await actions.openGoal(project, thread) } catch { session.actionError = "\(error)" }
    }
}
