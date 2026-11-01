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

    /// Whether the task the approve card is for was approved before (so the card says it was edited since).
    func selectedIsStale(_ project: Project?) -> Bool {
        guard let card = approving, let shown = snapshot(for: project) else { return false }
        return shown.entries.first { $0.id == card.name }?.summary.approval == .stale
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

    /// Opens the approve card with what is on disk now (so what is approved is what is shown).
    func beginApprove(_ project: Project?, _ name: String) {
        guard let project, runningTask == nil else { return }
        approveError = nil
        do { approving = try actions.inspect(project, name) } catch {
            approving = nil
            actionNote = "\(name) cannot be approved: \(error)"
        }
    }

    func cancelApprove() { (approving, approveError) = (nil, nil) }

    /// Records the approval. A refusal leaves the card open with core's words; nothing is recorded.
    func confirmApprove(_ project: Project?) async {
        guard let project, let card = approving else { return }
        do {
            try await actions.approve(project, card.name, card.hash)
            (approving, approveError, actionNote) = (nil, nil, nil)
            await refresh(project)
        } catch {
            approveError = "\(error)"
        }
    }

    // MARK: run

    /// `Run now`: asks first, whatever the task does, because either kind starts an agent that spends.
    func beginRun(_ project: Project?, _ entry: TaskEntry, threadRunGoing: Bool) async {
        guard let project else { return }
        if let why = runUnavailable(entry, threadRunGoing: threadRunGoing) {
            actionNote = why
            return
        }
        actionNote = nil
        // What the task is now, not what the list last read: a report task changed to `fix: pr` still asks first.
        let card: TaskCardInfo
        do { card = try actions.inspect(project, entry.id) } catch {
            actionNote = "\(entry.id) cannot run: \(error)"
            return
        }
        confirmingRun = card
    }

    func cancelRun() { confirmingRun = nil }

    func confirmRun(_ project: Project?) async {
        guard let project, let card = confirmingRun else { return }
        confirmingRun = nil
        // The card named a cost: run only the version it was for.
        guard let now = try? actions.inspect(project, card.name), now.hash == card.hash, now.cost == card.cost else {
            actionNote = "\(card.name) was edited after the card was shown: look at it again."
            await refresh(project)
            return
        }
        await startRun(project, card.name)
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
