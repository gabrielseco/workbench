import Foundation
import WorkbenchCore

/// What the Run settings say about the advice (the judge and the review stages) a turn is followed by, and what its switch does. The
/// steps are `ReviewConfig.advicePlan`, the function a run asks, so the line under the switch is what a run will do.
struct AutoAdviceSetting: Equatable {
    /// The goal's own `auto_advance`; nil follows the project.
    var goalSays: Bool?
    /// The project's `[review] auto_advance`.
    var projectSwitch = false
    /// The project's `[review] auto`: when it lists anything, it decides and the switch adds nothing.
    var projectList: [String] = []
    /// The steps a run of this goal is followed by, in order.
    var steps: [String] = []

    static let none = AutoAdviceSetting()

    static func read(goal: Goal, config: Config?) -> AutoAdviceSetting {
        guard let review = config?.review else { return AutoAdviceSetting(goalSays: goal.autoAdvance) }
        return AutoAdviceSetting(
            goalSays: goal.autoAdvance, projectSwitch: review.autoAdvance, projectList: review.auto,
            steps: review.advicePlan(goalAutoAdvance: goal.autoAdvance).names)
    }

    static let label = "Run the judge and review stages by themselves"

    /// The advice runs by itself after a passing turn.
    var on: Bool { !steps.isEmpty }

    /// The switch changes something only while the project has not said which steps itself.
    var adjustable: Bool { projectList.isEmpty }

    /// Whether the switch can be pressed: the settings may be changed now (`ProjectStore.goalEditable`) and the project has not said
    /// which steps itself.
    func switchEnabled(editable: Bool) -> Bool { editable && adjustable }

    var line: String {
        if !projectList.isEmpty {
            return "The project's [review] auto lists \(projectList.joined(separator: ", ")): the switch adds nothing."
        }
        return on ? "Runs: \(steps.joined(separator: ", "))" : "Off"
    }

    /// Where the setting comes from: the goal's key is approved with the goal, the project's is not.
    var source: String {
        if !projectList.isEmpty { return "From the project's config." }
        return goalSays == nil ? "From the project's config." : "Set for this goal."
    }

    /// The edit a press makes. When the new value is what the project already does the key is cleared, not set: the approval binds a
    /// key that is there, and one that only repeats the config would cost a re-approval for nothing.
    func toggled() -> GoalEdit {
        let target = !on
        return .setAutoAdvance(target == projectSwitch ? nil : target)
    }
}
