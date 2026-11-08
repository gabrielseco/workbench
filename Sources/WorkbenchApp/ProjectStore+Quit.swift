import Foundation

/// What a quit says and does when work of this app is still going.
enum QuitPrompt {
    /// What would be ended, in a line; nil when nothing is going.
    static func work(
        threadRunsIn projects: [String], taskRun: String?, drafting: Bool = false, chatting: Bool = false, editing: Bool = false
    ) -> String? {
        var parts: [String] = []
        // One part per project, in the order the runs were found: a project with several threads running says how many.
        var counts: [(project: String, runs: Int)] = []
        for project in projects {
            if let at = counts.firstIndex(where: { $0.project == project }) { counts[at].runs += 1 } else {
                counts.append((project, 1))
            }
        }
        for (project, runs) in counts { parts.append(runs == 1 ? "a run in \(project)" : "\(runs) runs in \(project)") }
        if let taskRun { parts.append("the task \(taskRun)") }
        if drafting { parts.append("a goal draft") }
        if chatting { parts.append("a chat turn") }
        if editing { parts.append("a task edit") }
        guard !parts.isEmpty else { return nil }
        let plural = parts.count > 1 || counts.contains { $0.runs > 1 }
        return parts.joined(separator: " and ") + (plural ? " are" : " is") + " still going."
    }

    static let detail =
        "Quitting stops the agent's turn; it ends as stopped, so nothing is lost and you can run it again. "
        + "Cancel keeps Workbench open."
}

extension ProjectStore {
    /// The runs this app holds, one per thread at most: threads run side by side up to `max_active_threads`.
    var ownedRuns: [ThreadSession.OwnedRun] { sessions.values.compactMap(\.ownedRun) }

    /// The project this app has a run going in, if any (the first, when threads of several projects are running).
    var runningProjectPath: String? { ownedRuns.first?.project.root.path }

    /// Every project this app has a run going in.
    var runningProjectPaths: Set<String> { Set(ownedRuns.map(\.project.root.path)) }

    /// Asks every run this app holds, in whichever thread, to end (a quit), all at once: each still ends with a recorded `stopped`.
    func stopOwnedRun() async {
        await withTaskGroup(of: Void.self) { group in
            for run in ownedRuns { group.addTask { await run.handle.stop() } }
        }
    }

    /// What a quit would end right now, as a line for the confirmation; nil when nothing is going.
    var liveWork: String? {
        QuitPrompt.work(
            threadRunsIn: ownedRuns.map { $0.project.root.lastPathComponent }, taskRun: tasks.runningTask,
            drafting: drafting, chatting: chatReplying, editing: tasks.isEditing)
    }

    /// Asks everything of this app's that is going (every thread run, the task run, the goal draft, a task edit) to end, all at once, and waits until
    /// it has, for `timeout` in all: a turn that has not ended by then is left, and the next start records it as interrupted.
    func stopWorkAndWait(timeout: Duration = .seconds(6)) async {
        guard liveWork != nil else { return }
        let deadline = ContinuousClock.now + timeout
        async let draft: Void = stopDraftingAndWait(timeout: timeout)
        async let chat: Void = stopChatAndWait(timeout: timeout)
        async let task: Void = tasks.stopAndWait(timeout: timeout)
        async let edit: Void = tasks.stopEditAndWait(timeout: timeout)
        await stopOwnedRun()
        while runningProjectPath != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        _ = await (draft, chat, task, edit)
    }
}
