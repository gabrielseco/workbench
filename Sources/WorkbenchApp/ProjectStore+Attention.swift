import Foundation
import WorkbenchCore

extension ProjectStore {
    /// The thread's own attention, as the screen shows it, for the attention centre.
    private var threadAttention: ThreadAttention? {
        guard case .thread(let shown) = screen else { return nil }
        // With a pull request open its CI arrives a moment after the thread: until it does, a CI failure cannot be told from none.
        let waitingForCI = shown.state.pullRequest != nil && shown.state.decision == "accepted" && shown.ci == nil
        return ThreadAttention(id: shown.id, title: shown.title, attention: shown.attention, ciLoaded: !waitingForCI)
    }

    /// Gives the attention centre one look at the project. The tasks are read (off the main actor, without the timer's probes) only when
    /// asked: the thread's attention changes with the log and is cheap, the tasks change with a tick.
    func observeAttention(readTasks: Bool) async {
        guard let project else {
            await attention.observe(project: nil, projectName: "", thread: nil, tasks: nil)
            return
        }
        var entries: [TaskEntry]?
        var failure: String?
        if readTasks {
            do {
                entries = try await Task.detached { try TasksReader.entries(project, now: Date()) }.value
            } catch { failure = "\(error)" }
        }
        // The project may have changed while the tasks were read: that answer is for the one left behind.
        guard project == self.project else { return }
        await attention.observe(
            project: project.root.path, projectName: project.root.lastPathComponent, thread: threadAttention,
            tasks: readTasks ? entries : nil, taskReadError: failure)
    }

    /// Reads the project's tasks every 30 s for as long as the app runs, whatever screen or window is up.
    func startAttentionPolling() {
        attention.startPolling { [weak self] in await self?.observeAttention(readTasks: true) }
    }

    /// Where a click on a notification (or an `Open` in the popover) goes. The window is brought forward by the caller.
    /// What `Open` and `Send back…` in the popover do before the window is brought forward: show the place, and for a send back open
    /// the existing card (the popover itself decides nothing).
    func openFromPopover(_ route: AttentionRoute, sendBack: Bool) {
        show(route, project: project?.root.path)
        if sendBack && route.isThread && review != nil { (actionError, sendingBack) = (nil, true) }
    }

    /// A route for another project than the one open is not acted on: it only brings the window forward.
    func show(_ route: AttentionRoute, project path: String? = nil) {
        if let path, path != project?.root.path {
            actionNote = "That was about \(URL(fileURLWithPath: path).lastPathComponent), which is not the project open now."
            return
        }
        switch route {
        case .thread:
            mode = .thread
        case .task(let name):
            mode = .tasks
            tasks.selection = name
        }
    }
}
