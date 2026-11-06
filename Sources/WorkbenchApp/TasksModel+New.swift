import Foundation
import WorkbenchCore

/// The New task screen: a name and the person's words, and what came back for them.
struct NewTaskDraft: Equatable {
    enum Phase: Equatable {
        case idle
        case working
        /// The agent's file loaded: what it would create, for the person to accept or discard.
        case proposed(TaskProposal, cost: String)
        case failed(String)
    }

    var name = ""
    var request = ""
    var phase: Phase = .idle
}

/// What a name typed for a new task is, before anything is asked.
enum TaskNameCheck: Equatable {
    case empty, invalid, taken, ok

    var message: String? {
        switch self {
        case .empty, .ok: nil
        case .invalid: "Use letters, digits, '.', '_' and '-'."
        case .taken: "A task with this name exists already."
        }
    }
}

extension TasksModel {
    func beginNew() {
        if creating == nil { creating = NewTaskDraft() }
    }

    /// Closes the screen. The words are dropped with it; Discard, on a proposal, keeps them.
    func cancelNew() {
        guard creating?.phase != .working else { return }
        creating = nil
    }

    func nameCheck(_ typed: String, in project: Project?) -> TaskNameCheck {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .empty }
        guard TaskScaffold.isUsableName(name) else { return .invalid }
        let listed = snapshot(for: project)?.entries.contains { $0.id == name } ?? false
        if listed || (project.map { FileManager.default.fileExists(atPath: $0.taskDirectory(name).path) } ?? false) {
            return .taken
        }
        return .ok
    }

    /// Why Propose is off, nil when it can start: a good name and some words, a goal agent, and nothing already going.
    func proposeNewUnavailable(in project: Project?) -> String? {
        guard let draft = creating else { return "No task is being made." }
        if draft.phase == .working { return "The agent is working: one at a time." }
        if nameCheck(draft.name, in: project) != .ok {
            return draft.name.isEmpty ? "Name the task first." : "That name cannot be used."
        }
        if draft.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what the task should do first." }
        return editLimit == nil ? "Needs a goal agent: set [agents.goal] in .workbench/config.toml." : nil
    }

    /// Asks the agent for the task file. Nothing is created: the answer is a proposal until `acceptNew`.
    func proposeNew(_ project: Project?) async {
        guard let project, var draft = creating, proposeNewUnavailable(in: project) == nil else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = draft.request.trimmingCharacters(in: .whitespacesAndNewlines)
        let stop = DraftStop()
        createStop = stop
        draft.phase = .working
        creating = draft
        let actions = self.actions
        var phase = NewTaskDraft.Phase.idle
        do {
            let result = try await actions.proposeNew(project, name, request, stop)
            let cost = result.costUSD.map { String(format: "$%.4f", $0) } ?? "cost unknown"
            if let proposal = result.proposal {
                phase = .proposed(proposal, cost: cost)
            } else {
                let said = stop.wasRequested ? "Stopped." : "No task (\(cost)): \(result.failure ?? "no proposal")."
                phase = .failed(said + " Nothing was created.")
            }
        } catch { phase = .failed("\(error)") }
        createStop = nil
        // The screen may have been closed or changed while it worked: only the draft that asked is given the answer.
        if creating?.name == draft.name { creating?.phase = phase }
    }

    /// Creates the task the proposal described. Returns its name when it exists, for the caller to show; a refusal (the name was taken
    /// meanwhile) is said on the screen and nothing is created.
    func acceptNew(_ project: Project?) async -> String? {
        guard let project, case .proposed(let proposal, _)? = creating?.phase else { return nil }
        let actions = self.actions
        do {
            try await actions.acceptEdit(project, proposal)
        } catch {
            creating?.phase = .failed("\(error)")
            return nil
        }
        creating = nil
        await refresh(project)
        return proposal.task
    }

    /// The template `workbench task new` makes, with no agent: the same `TaskScaffold`, so the app and the command cannot drift.
    func createEmpty(_ project: Project?) async -> String? {
        guard let project, let draft = creating, draft.phase != .working else { return nil }
        guard nameCheck(draft.name, in: project) == .ok else { return nil }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let scaffold = actions.scaffold
        do {
            try scaffold(project, name)
        } catch {
            creating?.phase = .failed("\(error)")
            return nil
        }
        creating = nil
        await refresh(project)
        return name
    }

    /// Back to the words, keeping them.
    func discardNew() {
        if creating != nil { creating?.phase = .idle }
    }
}
