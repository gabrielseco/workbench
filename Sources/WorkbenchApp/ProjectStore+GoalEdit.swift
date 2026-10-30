import Foundation
import WorkbenchCore

extension ProjectStore {
    /// Makes one edit to the draft goal on screen, then reads the file again. A refusal (a run holds the thread, the edit would
    /// not parse) is said under the blocks and the file is as it was. Edits are small and frequent, so there is no busy line.
    func editGoal(_ edit: GoalEdit) async {
        guard let project, let thread = currentThread else { return }
        let mine = generation
        do {
            try await actions.editGoal(project, thread, edit)
            if mine == generation { goalEditError = nil }
        } catch {
            if mine == generation { goalEditError = "\(error)" }
        }
        await reload()
    }
}
