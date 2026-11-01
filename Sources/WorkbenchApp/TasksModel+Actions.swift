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
            try await actions.approve(project, card.name)
            (approving, approveError, actionNote) = (nil, nil, nil)
            await refresh(project)
        } catch {
            approveError = "\(error)"
        }
    }

    // MARK: run

    /// `Run now`: a `fix: report` task starts at once (it starts no agent); a `fix: pr` task asks first.
    func beginRun(_ project: Project?, _ entry: TaskEntry, threadRunGoing: Bool) async {
        guard let project else { return }
        if let why = runUnavailable(entry, threadRunGoing: threadRunGoing) {
            actionNote = why
            return
        }
        actionNote = nil
        guard entry.summary.fix == .pr else {
            await startRun(project, entry.id)
            return
        }
        do { confirmingRun = try actions.inspect(project, entry.id) } catch {
            actionNote = "\(entry.id) cannot run: \(error)"
        }
    }

    func cancelRun() { confirmingRun = nil }

    func confirmRun(_ project: Project?) async {
        guard let project, let card = confirmingRun else { return }
        confirmingRun = nil
        await startRun(project, card.name)
    }

    private func startRun(_ project: Project, _ name: String) async {
        guard runningTask == nil else {
            actionNote = "A run of \(runningTask ?? "a task") is going: one at a time from this window."
            return
        }
        let stop = TaskStopSwitch()
        stopSwitch = stop
        (runningTask, runSaid, lastResult, actionNote) = (name, "Starting \(name)…", nil, nil)
        let actions = self.actions
        // The run says what it is doing as it goes; the screen shows the last line.
        let said = SaidBox { [weak self] line in Task { @MainActor in self?.runSaid = line } }
        let result = await actions.run(project, name, stop) { said.say($0) }
        (runningTask, runSaid, stopSwitch, lastResult) = (nil, nil, nil, (name, result))
        await refresh(project)
    }

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
