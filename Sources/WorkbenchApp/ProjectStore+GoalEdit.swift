import Foundation
import WorkbenchCore

extension ProjectStore {
    /// Makes one edit to the draft goal on screen, then reads the file again. A refusal (a run holds the thread, the edit would
    /// not parse) is said under the blocks and the file is as it was. Edits are small and frequent, so there is no busy line.
    func editGoal(_ edit: GoalEdit) async { await editGoal { _ in edit } }

    /// The same, with the edit made from the goal as it is when its turn comes. Edits run one at a time, each after the last
    /// one's reload, so two quick clicks (two switches, two list items) each build on the other's result and none is lost.
    /// `make` may answer nil when the goal no longer has what the click was about.
    func editGoal(_ make: @escaping @MainActor (GoalModel) -> GoalEdit?) async {
        // The goal an edit is for is the one on screen when it was made: if the window has moved to another project or thread by
        // the time its turn comes, it is dropped.
        let target = (generation, currentThread)
        let previous = goalEdits
        let task = Task { @MainActor in
            await previous?.value
            guard target == (generation, currentThread) else { return }
            await perform(make)
        }
        goalEdits = task
        await task.value
    }

    private func perform(_ make: @MainActor (GoalModel) -> GoalEdit?) async {
        guard let project, let thread = currentThread, let goal, let edit = make(goal) else { return }
        let mine = generation
        do {
            try await actions.editGoal(project, thread, edit)
            if mine == generation { goalEditError = nil }
        } catch {
            if mine == generation { goalEditError = "\(error)" }
        }
        await reload()
        // Fields that were refused show what the file has again.
        if mine == generation { goalEditSerial += 1 }
    }
}
