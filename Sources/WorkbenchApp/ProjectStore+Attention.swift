import Foundation
import WorkbenchCore

extension ProjectStore {
    /// The thread's own attention, as the screen shows it, for the attention centre.
    private var threadAttention: ThreadAttention? {
        guard case .thread(let shown) = screen else { return nil }
        return ThreadAttention(id: shown.id, title: shown.title, attention: shown.attention)
    }

    /// Gives the attention centre one look at the project. The tasks are read (off the main actor, without the timer's probes) only when
    /// asked: the thread's attention changes with the log and is cheap, the tasks change with a tick.
    func observeAttention(readTasks: Bool) async {
        guard let project else {
            await attention.observe(project: nil, projectName: "", thread: nil, tasks: nil)
            return
        }
        var entries: [TaskEntry]?
        if readTasks {
            entries = try? await Task.detached { try TasksReader.entries(project, now: Date()) }.value
        }
        // The project may have changed while the tasks were read: that answer is for the one left behind.
        guard project == self.project else { return }
        await attention.observe(
            project: project.root.path, projectName: project.root.lastPathComponent, thread: threadAttention,
            tasks: readTasks ? entries : nil)
    }

    /// Reads the project's tasks every 30 s for as long as the app runs, whatever screen or window is up.
    func startAttentionPolling() {
        attention.startPolling { [weak self] in await self?.observeAttention(readTasks: true) }
    }

    /// Where a click on a notification (or an `Open` in the popover) goes. The window is brought forward by the caller.
    func show(_ route: AttentionRoute) {
        switch route {
        case .thread:
            mode = .thread
        case .task(let name):
            mode = .tasks
            tasks.selection = name
            attention.markSeen(task: name)
        }
    }
}
