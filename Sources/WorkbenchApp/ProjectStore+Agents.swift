import Foundation
import WorkbenchCore

extension ProjectStore {
    /// Reads the project's config again for the Agents card and the agent a chat names. A config that does not load leaves nothing to
    /// show (the Doctor and the actions say why); nothing is written.
    func refreshAgentSetup() async {
        guard let project else {
            agentSetup = nil
            return
        }
        let url = project.configURL
        let setup = await Task.detached { (try? Config.load(from: url)).map { AgentSetup(config: $0) } }.value
        // The project may have changed while the file was read.
        if self.project?.configURL == url { agentSetup = setup }
    }

    /// What a chat's footer says about its agent: the provider and model, or that none is set. Nil until the config has been read.
    var chatAgentNote: String? {
        guard let goal = agentSetup?.row(.goal) else { return nil }
        return goal.label ?? "no goal agent is set, so replies are off"
    }
}
