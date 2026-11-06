import Foundation
import WorkbenchCore

/// Where an edit of a task stands. Only one at a time, for one task of one project.
struct TaskEditing: Equatable {
    enum Phase: Equatable {
        case working
        /// The agent's file loaded: what it changes, for the person to accept or discard. `cost` is how it says what was spent.
        case proposed(TaskProposal, cost: String)
        case failed(String)
    }

    var project: String
    var task: String
    var phase: Phase
}

extension TasksModel {
    /// The edit shown for this task of this project, if one is.
    func editing(_ name: String, in project: Project?) -> TaskEditing? {
        guard let editing, editing.task == name, editing.project == project?.root.path else { return nil }
        return editing
    }

    private func editKey(_ name: String, in project: Project?) -> String { "\(project?.root.path ?? "")|\(name)" }

    /// The card is shown once the button opened it, and for as long as an edit of the task is working or waiting for a decision.
    func isEditShown(_ name: String, in project: Project?) -> Bool {
        editOpen.contains(editKey(name, in: project)) || editing(name, in: project) != nil
    }

    /// The button: opens the card, or closes it when it is open and has nothing in it to decide.
    func toggleEdit(_ name: String, in project: Project?) {
        guard editing(name, in: project) == nil else { return }
        let key = editKey(name, in: project)
        if editOpen.remove(key) == nil { editOpen.insert(key) }
    }

    /// Why Fix this is off for a run of this task, nil when it works: an edit that is working or waiting is the person's to finish first.
    func fixUnavailable(_ name: String, in project: Project?) -> String? {
        editing(name, in: project) == nil ? nil : "An edit is open: accept or discard it first."
    }

    /// Opens the card with what went wrong in this run in its box, under whatever the person had typed. Asks the agent nothing: the
    /// person adds their words, or presses Propose, and only then is anything spent.
    func fixThis(_ project: Project?, _ name: String, _ run: TaskHistory.Run, detail: TaskRunDetail?) {
        guard run.outcome != nil, fixUnavailable(name, in: project) == nil else { return }
        let text = TaskEdit.runRequest(run: run, detail: detail)
        let typed = editRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        editRequest = typed.isEmpty ? text : typed + "\n\n" + text
        if !isEditShown(name, in: project) { toggleEdit(name, in: project) }
        editFocus += 1
    }

    /// Why `Propose` is off for this task, nil when it can start.
    func editUnavailable(_ entry: TaskEntry) -> String? {
        if entry.summary.problem != nil { return "The task does not load: fix its task.md first." }
        if case .working? = editing?.phase { return "An edit is going: one at a time." }
        if entry.isRunning || runningTask == entry.id { return "A run of this task is going: wait for it to end." }
        return nil
    }

    /// Asks the agent for a new task.md. Nothing is written: the answer is a proposal until `acceptEdit`.
    func proposeEdit(_ project: Project?, _ entry: TaskEntry) async {
        guard let project else { return }
        let request = editRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        if let why = editUnavailable(entry) {
            actionNote = why
            return
        }
        let stop = DraftStop()
        editStop = stop
        let key = TaskEditing(project: project.root.path, task: entry.id, phase: .working)
        (editing, actionNote) = (key, nil)
        let actions = self.actions
        var next = key
        do {
            let result = try await actions.edit(project, entry.id, request, stop)
            let cost = result.costUSD.map { String(format: "$%.4f", $0) } ?? "cost unknown"
            if let proposal = result.proposal {
                next.phase = .proposed(proposal, cost: cost)
            } else {
                let why = result.failure ?? "no proposal"
                let said = stop.wasRequested ? "Stopped." : "No edit (\(cost)): \(why)."
                next.phase = .failed(said + " Nothing was written.")
            }
        } catch { next.phase = .failed("\(error)") }
        editStop = nil
        // Another task or project may have been chosen while it worked; the answer is still this edit's, and is shown where it began.
        editing = next
    }

    func stopEdit() { editStop?.stop() }

    /// An edit is with the agent: a quit has to end it, or its process goes on spending.
    var isEditing: Bool { editing?.phase == .working }

    /// Stops the agent of an edit and waits until the edit has ended, at most `timeout` (a quit).
    func stopEditAndWait(timeout: Duration = .seconds(6)) async {
        guard isEditing else { return }
        let deadline = ContinuousClock.now + timeout
        stopEdit()
        while isEditing, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Writes the proposal. A refusal (the file changed, a run is going) leaves it shown with the core's words; nothing is written.
    func acceptEdit(_ project: Project?) async {
        guard let project, case .proposed(let proposal, _)? = editing?.phase else { return }
        let actions = self.actions
        do {
            try await actions.acceptEdit(project, proposal)
            (editing, editRequest, actionNote) = (nil, "", nil)
            editOpen.removeAll()
            await refresh(project)
        } catch {
            editing?.phase = .failed("\(error)")
        }
    }

    func discardEdit() { editing = nil }
}
