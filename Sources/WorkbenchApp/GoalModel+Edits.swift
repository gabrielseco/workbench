import Foundation
import WorkbenchCore

/// The edits the Goal screen and the feed's Run settings make, built once from the goal as it is when they run, so the two cannot differ.
extension GoalModel {
    /// A switch pressed: the step is skipped for this goal, or no longer, and the other skipped steps stay as they are.
    func togglingSkip(_ name: String) -> GoalEdit {
        let others = steps.filter { $0.skipped && $0.name != name }.map(\.name)
        let skipped = steps.first { $0.name == name }?.skipped ?? false
        return .setSkip(skipped ? others : others + [name])
    }

    func addingReadAlso(_ folder: String) -> GoalEdit { .setReadAlso(goalReadAlso + [folder]) }

    /// nil when the goal no longer has that folder.
    func removingReadAlso(_ folder: String) -> GoalEdit? {
        guard let at = goalReadAlso.firstIndex(of: folder) else { return nil }
        var all = goalReadAlso
        all.remove(at: at)
        return .setReadAlso(all)
    }

    func addingOutOfScope(_ item: String) -> GoalEdit { .setOutOfScope(outOfScope + [item]) }

    /// nil when the goal no longer has the item the click was about.
    func replacingOutOfScope(_ item: String, with new: String) -> GoalEdit? {
        guard let at = outOfScope.firstIndex(of: item) else { return nil }
        var items = outOfScope
        items[at] = new
        return .setOutOfScope(items)
    }

    func removingOutOfScope(_ item: String) -> GoalEdit? {
        guard let at = outOfScope.firstIndex(of: item) else { return nil }
        var items = outOfScope
        items.remove(at: at)
        return .setOutOfScope(items)
    }
}
