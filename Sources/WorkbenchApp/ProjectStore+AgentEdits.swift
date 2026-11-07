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

    /// The goal agent off: its provider, model and effort go together, so the config still loads (a goal table needs a provider).
    @discardableResult
    func turnGoalAgentOff() async -> Bool {
        await edit(role: .goal) { project in
            for field in [ConfigEdit.Field.model, .reasoningEffort, .provider] {
                try Self.remove(ConfigEdit.Key(role: .goal, field: field), in: project)
            }
        }
    }

    /// Removing a key that is not set is already what was asked.
    private nonisolated static func remove(_ key: ConfigEdit.Key, in project: Project) throws {
        do { _ = try ConfigEdit.unset(key, in: project) } catch ConfigEdit.Failure.notSet { return }
    }

    /// True when the edit was written (or was already what the file said).
    private func edit(role: AgentRole, _ work: @escaping @Sendable (Project) throws -> Void) async -> Bool {
        guard let project else { return false }
        let failure = await Task.detached { () -> String? in
            do {
                try work(project)
                return nil
            } catch { return "\(error)" }
        }.value
        actionError = failure
        actionNote = failure == nil && role == .run ? AgentSetup.runChangeNote(in: project) : nil
        await refreshAgentSetup()
        return failure == nil
    }
}
