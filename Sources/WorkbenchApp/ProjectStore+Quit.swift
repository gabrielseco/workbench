import Foundation

/// What a quit says and does when work of this app is still going.
enum QuitPrompt {
    /// What would be ended, in a line; nil when nothing is going.
    static func work(threadRunIn project: String?, taskRun: String?, drafting: Bool = false) -> String? {
        var parts: [String] = []
        if let project { parts.append("a run in \(project)") }
        if let taskRun { parts.append("the task \(taskRun)") }
        if drafting { parts.append("a goal draft") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " and ") + (parts.count > 1 ? " are" : " is") + " still going."
    }

    static let detail =
        "Quitting stops the agent's turn; it ends as stopped, so nothing is lost and you can run it again. "
        + "Cancel keeps Workbench open."
}

extension ProjectStore {
    /// What a quit would end right now, as a line for the confirmation; nil when nothing is going.
    var liveWork: String? {
        QuitPrompt.work(
            threadRunIn: runningProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent }, taskRun: tasks.runningTask,
            drafting: drafting)
    }

    /// Asks everything of this app's that is going (the thread run, the task run, the goal draft) to end, all at once, and waits until
    /// it has, for `timeout` in all: a turn that has not ended by then is left, and the next start records it as interrupted.
    func stopWorkAndWait(timeout: Duration = .seconds(6)) async {
        guard liveWork != nil else { return }
        let deadline = ContinuousClock.now + timeout
        async let draft: Void = stopDraftingAndWait(timeout: timeout)
        async let task: Void = tasks.stopAndWait(timeout: timeout)
        await stopOwnedRun()
        while runningProjectPath != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        _ = await (draft, task)
    }
}
