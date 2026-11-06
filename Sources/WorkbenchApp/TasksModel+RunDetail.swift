import Foundation
import WorkbenchCore

extension TasksModel {
    /// A run's row, for this project's task: a task of the same name in another project, or a run at another time, is not it.
    static func runKey(_ project: Project?, _ task: String, _ run: TaskHistory.Run) -> String {
        "\(project?.root.path ?? "")|\(task)|\(run.started.timeIntervalSince1970)"
    }

    func detail(_ project: Project?, _ task: String, _ run: TaskHistory.Run) -> TaskRunDetail? {
        runDetails[Self.runKey(project, task, run)]
    }

    func isOpen(_ project: Project?, _ task: String, _ run: TaskHistory.Run) -> Bool {
        openRuns.contains(Self.runKey(project, task, run))
    }

    /// Opens or closes a run's row. Opening reads what the run did, off the main actor: its thread's log can be large.
    func toggleRun(_ project: Project?, _ task: String, _ run: TaskHistory.Run) async {
        let key = Self.runKey(project, task, run)
        if openRuns.remove(key) != nil { return }
        openRuns.insert(key)
        guard let project else { return }
        let read = actions.detail
        let detail = await Task.detached { read(project, run) }.value
        // Closed again while it was reading: nothing is shown for it.
        if openRuns.contains(key) { runDetails[key] = detail }
    }
}
