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

    /// Whether an Agents card is up; setting it true opens the open project's, false closes whichever is up.
    var showingAgents: Bool {
        get { agentsProject != nil }
        set { agentsProject = newValue ? project?.root.path : nil }
    }

    /// What the Agents card shows: the roles of the project it was opened for.
    var cardAgentSetup: AgentSetup? {
        if case .read(let setup) = cardAgentConfig { return setup }
        return nil
    }

    /// The project the Agents card is about, as core's `Project` (its config file is where edits go).
    var agentsProjectValue: Project? { agentsProject.map { Project(root: URL(fileURLWithPath: $0)) } }

    /// Opens the Agents card for the project at `path`, or for the open one. A project that is not the open one is edited where it
    /// is: nothing about the open project changes.
    func showAgents(for path: String? = nil) {
        guard let target = path ?? project?.root.path else { return }
        pickingProject = false
        cardAgentConfig = .unread
        agentsProject = target
    }

    /// Reads the config of the project the card is for. A config that does not load leaves nothing to show; nothing is written.
    func refreshCardAgents() async {
        guard let target = agentsProjectValue else {
            cardAgentConfig = .unread
            return
        }
        let url = target.configURL
        let found = await Task.detached { Self.readAgentConfig(at: url) }.value
        if agentsProjectValue?.configURL == url { cardAgentConfig = found }
    }

    nonisolated static func readAgentConfig(at url: URL) -> AgentConfigState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        return (try? Config.load(from: url)).map { .read(AgentSetup(config: $0)) } ?? .unreadable
    }

    /// Reads the project's config again for the Agents card and the agent a chat names. A config that does not load leaves nothing to
    /// show (the Doctor and the actions say why); nothing is written.
    func refreshAgentSetup() async {
        guard let project else {
            agentConfig = .unread
            return
        }
        let url = project.configURL
        let found = await Task.detached { Self.readAgentConfig(at: url) }.value
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
