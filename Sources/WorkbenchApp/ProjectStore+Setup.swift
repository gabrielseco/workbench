import Foundation
import WorkbenchCore

/// Setting up a folder that is a git repository but not yet a Workbench project, from the window: what the person picked and how it went.
struct ProjectSetupState: Equatable {
    /// Who discusses and drafts goals in the new project; nil leaves goal drafting off. Claude unless the person picks otherwise.
    var goalAgent: AgentProviderID? = .claude
    /// The person chose "Not now": the window says what is missing and offers setup again, and nothing was written.
    var skipped = false
    var running = false
    /// Why the last try failed, in core's words; the screen offers it again ("Try again").
    var failure: String?
    /// What the last setup did, said once on the next screen.
    var done: String?

    /// The choices the screen offers for the goal agent: the providers that can draft, and none.
    static let goalAgentChoices: [AgentProviderID?] = AgentRole.goal.supportedProviders.map { $0 } + [nil]
}

extension ProjectStore {
    /// The open project has no `.workbench/` yet and the person has not put setting it up off.
    var offersSetup: Bool {
        guard project != nil, case .workbenchMissing = screen else { return false }
        return !setup.skipped
    }

    func pickSetupGoalAgent(_ provider: AgentProviderID?) {
        guard !setup.running else { return }
        setup.goalAgent = provider
    }

    /// "Not now": the folder is left exactly as it was, and the window says how to set it up later.
    func skipSetup() {
        guard !setup.running else { return }
        (setup.skipped, setup.failure) = (true, nil)
    }

    /// Back to the setup offer from the screen that says it was put off.
    func resumeSetup() { setup.skipped = false }

    /// Sets up Workbench in the open folder with the goal agent picked. On success the project opens on New goal when it has a goal
    /// agent, so the person can discuss or draft straight away; a failure stays on the setup screen with core's reason and a retry.
    func initializeProject() async {
        guard let project, case .workbenchMissing = screen, !setup.running else { return }
        let (mine, agent) = (generation, setup.goalAgent)
        (setup.running, setup.failure, setup.done) = (true, nil, nil)
        let initialize = actions.initializeProject
        let outcome: Result<ProjectSetup.Report, Error>
        do { outcome = .success(try await initialize(project, agent)) } catch { outcome = .failure(error) }
        // Another folder was opened meanwhile: this answer is not for the one on screen.
        guard mine == generation else { return }
        setup.running = false
        switch outcome {
        case .failure(let error):
            setup.failure = "\(error)"
        case .success(let report):
            setup.done = Self.setupNote(report)
            agentConfig = .unread
            goalAgentOff = false
            await reload()
            if report.goalAgent != nil, screen == .noThread { openNewThread() }
        }
    }

    /// What setup did, in a sentence.
    nonisolated static func setupNote(_ report: ProjectSetup.Report) -> String {
        let config = report.wroteConfig ? "Workbench is set up" : "Workbench kept the config that was there"
        guard let agent = report.goalAgent else {
            return config + ". No goal agent: name one in Agents to discuss or draft goals."
        }
        let kept = report.keptGoalAgent ? ", the goal agent the config already named" : ""
        return config + ". \(AgentSetup.name(agent))\(kept) discusses and drafts goals."
    }
}
