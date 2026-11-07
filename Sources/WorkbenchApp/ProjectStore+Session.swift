import Foundation
import WorkbenchCore

/// What the window shows about the thread on screen is held by its `ThreadSession`; these read and write the current one, so the
/// views and the actions say `store.actionError` as before.
extension ProjectStore {
    var goal: GoalModel? { current.goal }
    var review: ReviewModel? {
        get { current.review }
        set { current.review = newValue }
    }
    var actionError: String? {
        get { current.actionError }
        set { current.actionError = newValue }
    }
    var actionNote: String? {
        get { current.actionNote }
        set { current.actionNote = newValue }
    }
    var notice: String? {
        get { current.notice }
        set { current.notice = newValue }
    }
    var pendingDiscard: DiscardPlan? {
        get { current.pendingDiscard }
        set { current.pendingDiscard = newValue }
    }
    var goalEditError: String? {
        get { current.goalEditError }
        set { current.goalEditError = newValue }
    }
    var goalEditSerial: Int {
        get { current.goalEditSerial }
        set { current.goalEditSerial = newValue }
    }
    var goalEdits: Task<Void, Never>? {
        get { current.goalEdits }
        set { current.goalEdits = newValue }
    }
    var starting: Bool { current.starting }
    var stopping: Bool { current.stopping }
    /// The project and thread on screen, as one value to compare.
    var currentScope: String? { project.map { "\($0.root.path)|\(currentThread ?? "")" } }
}
