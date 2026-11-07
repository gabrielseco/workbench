import Foundation
import WorkbenchCore

extension ProjectStore {
    /// Sets one agent key through `ConfigEdit`, the code `workbench config set` runs, or removes it with a nil `value`. A refusal is said
    /// in the card; either way the card reads the config again, so the pickers show what the file has.
    @discardableResult
    func setAgent(_ role: AgentSetup.Role, _ field: ConfigEdit.Field, to value: String?) async -> Bool {
        guard let agentRole = AgentRole(rawValue: role.rawValue) else { return false }
        return await edit(role: agentRole) { project in
            let key = ConfigEdit.Key(role: agentRole, field: field)
            if let value { _ = try ConfigEdit.set(key, to: value, in: project) } else { try Self.remove(key, in: project) }
        }
    }

    /// The goal agent off: its whole table goes in one write, so the config still loads (a goal table needs a provider).
    @discardableResult
    func turnGoalAgentOff() async -> Bool {
        await edit(role: .goal) { project in _ = try ConfigEdit.removeRole(.goal, in: project) }
    }

    /// Removing a key that is not set is already what was asked.
    private nonisolated static func remove(_ key: ConfigEdit.Key, in project: Project) throws {
        do { _ = try ConfigEdit.unset(key, in: project) } catch ConfigEdit.Failure.notSet { return }
    }

    /// True when the edit was written (or was already what the file said).
    private func edit(role: AgentRole, _ work: @escaping @Sendable (Project) throws -> Void) async -> Bool {
        guard let project else { return false }
        // One at a time and in the order they were made, off the main thread; the note reads the thread logs, so it is made there too.
        let (failure, note) = await AgentEditQueue.shared.run { () -> (String?, String?) in
            do { try work(project) } catch { return ("\(error)", nil) }
            return (nil, role == .run ? AgentSetup.runChangeNote(in: project) : nil)
        }
        actionError = failure
        actionNote = note
        await refreshAgentSetup()
        return failure == nil
    }
}

/// The edits of the Agents card, run one after another in the order they arrived, so a later choice is never overwritten by an earlier one.
private actor AgentEditQueue {
    static let shared = AgentEditQueue()

    func run<T: Sendable>(_ work: @Sendable () -> T) -> T { work() }
}
