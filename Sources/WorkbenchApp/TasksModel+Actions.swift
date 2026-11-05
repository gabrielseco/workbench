import Foundation
import WorkbenchCore

extension TasksModel {
    /// Why `Run now` is off for this task, or nil when it can start: shown as the button's `.help`.
    func runUnavailable(_ entry: TaskEntry, threadRunGoing: Bool) -> String? {
        if entry.summary.problem != nil { return "The task does not load: fix its task.md first." }
        switch entry.summary.approval {
        case .never: return "Not approved: nothing runs unapproved."
        case .stale: return "Edited since it was approved: approve it again first."
        case .approved: break
        }
        if let running = runningTask { return "A run of \(running) is going from this window." }
        if threadRunGoing { return "This window's thread run is going: a project has one active run." }
        if entry.isRunning { return "A run of this task is already going." }
        return nil
    }

    var isRunning: Bool { runningTask != nil }

    /// Whether the run started here is for this project's task `name` (a task of the same name in another project is not it).
    func isRunning(_ name: String, in project: Project?) -> Bool {
        runningTask == name && runningProject == project?.root.path
    }

    /// How the last run started here ended, when it was this project's task `name`.
    func result(of name: String, in project: Project?) -> TaskRunResult? {
        guard let last = lastResult, last.project == project?.root.path, last.task == name else { return nil }
        return last.result
    }

    // MARK: approve

    /// Approves the task as it is on disk now: the hash read here is the one recorded, and core refuses it if the file changes between.
    func approve(_ project: Project?, _ name: String) async {
        guard let project, runningTask == nil else { return }
        do {
            let shown = try actions.inspect(project, name)
            try await actions.approve(project, name, shown.hash)
            actionNote = nil
            await refresh(project)
        } catch {
            actionNote = "\(name) cannot be approved: \(error)"
        }
    }

    // MARK: run

    /// `Run now`: starts the run at once. The task was approved, and the runner checks that approval against the file on disk itself.
    func beginRun(_ project: Project?, _ entry: TaskEntry, threadRunGoing: Bool) async {
        guard let project else { return }
        if let why = runUnavailable(entry, threadRunGoing: threadRunGoing) {
            actionNote = why
            return
        }
        await startRun(project, entry.id)
    }

    private func startRun(_ project: Project, _ name: String) async {
        guard runningTask == nil else {
            actionNote = "A run of \(runningTask ?? "a task") is going: one at a time from this window."
            return
        }
        let stop = TaskStopSwitch()
        stopSwitch = stop
        runningProject = project.root.path
        (runningTask, lastResult, actionNote) = (name, nil, nil)
        runSaid = "Running \(name), started \(startedAt()). Stop ends it."
        let actions = self.actions
        // The run says what it is doing as it goes; the screen shows the last line.
        let said = SaidBox { [weak self] line in Task { @MainActor in self?.runSaid = line } }
        let result = await actions.run(project, name, stop) { said.say($0) }
        (runningTask, runSaid, stopSwitch, runningProject) = (nil, nil, nil, nil)
        lastResult = RunOutcome(project: project.root.path, task: name, result: result)
        // Another project may be on screen by now: its tasks are not replaced by this one's.
        if latestPath == nil || latestPath == project.root.path { await refresh(project) }
    }

    /// Stops the run started here and waits until it has ended, at most `timeout` (a quit).
    func stopAndWait(timeout: Duration = .seconds(6)) async {
        guard runningTask != nil else { return }
        let deadline = ContinuousClock.now + timeout
        await stopRun()
        while runningTask != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// When the run began, as the busy line says it: the runner only reports as each step ends, so a long turn is silent until then.
    private func startedAt() -> String { Date().formatted(.dateTime.hour().minute()) }

    /// Ends the turn the way Ctrl-C does on `workbench task run`; the run still records how it ended.
    func stopRun() async {
        runSaid = "Stopping…"
        await stopSwitch?.stop()
    }
}

/// Carries a run's progress lines from wherever the runner is to the main actor.
private struct SaidBox: Sendable {
    let say: @Sendable (String) -> Void
    init(_ say: @escaping @Sendable (String) -> Void) { self.say = say }
}
