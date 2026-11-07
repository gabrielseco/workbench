import Foundation
import WorkbenchCore

/// What reading the project's config for the Agents card found.
enum AgentConfigState: Equatable {
    /// Not read yet.
    case unread
    /// The project has no `.workbench/config.toml`: every role runs its provider's default and there is no goal agent.
    case missing
    /// The file is there and does not load.
    case unreadable
    case read(AgentSetup)
}

extension ProjectStore {
    var agentSetup: AgentSetup? {
        if case .read(let setup) = agentConfig { return setup }
        return nil
    }

    var agentConfigMissing: Bool { agentConfig == .missing }

    /// Reads the project's config again for the Agents card and the agent a chat names. A config that does not load leaves nothing to
    /// show (the Doctor and the actions say why); nothing is written.
    func refreshAgentSetup() async {
        guard let project else {
            agentConfig = .unread
            return
        }
        let url = project.configURL
        let found: AgentConfigState = await Task.detached {
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            return (try? Config.load(from: url)).map { .read(AgentSetup(config: $0)) } ?? .unreadable
        }.value
        // The project may have changed while the file was read.
        if self.project?.configURL == url { agentConfig = found }
    }

    static let noGoalAgent = "no goal agent is set, so replies are off"

    /// What a chat's footer says about its agent: the provider and model, or that none is set. Nil until the config has been read.
    var chatAgentNote: String? {
        // A project with no config file has no goal agent either: a chat is refused there too.
        guard let goal = agentSetup?.row(.goal) else { return agentConfigMissing ? Self.noGoalAgent : nil }
        return goal.label ?? Self.noGoalAgent
    }
}
