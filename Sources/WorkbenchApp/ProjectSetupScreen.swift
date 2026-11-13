import SwiftUI
import WorkbenchCore

/// What the window shows for a git repository that is not a Workbench project yet: what setting it up writes, who discusses and drafts
/// goals, and Set up or Not now. Nothing is written before Set up; a failure says why and offers it again.
struct ProjectSetupScreen: View {
    var path: String
    var store: ProjectStore

    private var name: String { URL(fileURLWithPath: path).lastPathComponent }
    private var setup: ProjectSetupState { store.setup }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                heading
                goalAgent
                if let failure = setup.failure { Message(.error, "Setup failed: \(failure)") }
                actions
            }
            .frame(maxWidth: FeedLayout.maxColumn, alignment: .leading)
            .padding(.horizontal, Spacing.gutter).padding(.vertical, Space.huge).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Set up Workbench in \(name)").textStyle(.title)
            Text(
                "This folder is a git repository, but not a Workbench project yet. Setting it up adds .workbench/config.toml "
                    + "and keeps .workbench/ out of git status. Your files and any existing settings stay as they are."
            )
            .role(.detail).fixedSize(horizontal: false, vertical: true)
            Text((path as NSString).abbreviatingWithTildeInPath).role(.mono).lineLimit(1).truncationMode(.middle)
        }
    }

    private var goalAgent: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("GOAL AGENT")
            SegmentedSwitch(
                segments: ProjectSetupState.goalAgentChoices.map(Self.segment),
                selection: Self.id(setup.goalAgent), enabled: !setup.running
            ) { picked in
                store.pickSetupGoalAgent(ProjectSetupState.goalAgentChoices.first { Self.id($0) == picked }.flatMap { $0 })
            }
            .fixedSize()
            Text(agentNote).role(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agentNote: String {
        guard let agent = setup.goalAgent else {
            return "No goal agent: chat and drafting stay off until one is named in Agents. You can still write a goal as typed."
        }
        return "\(AgentSetup.name(agent)) talks a goal through with you and drafts it. It adds [agents.goal] to the config; "
            + "nothing runs and nothing costs until you start a chat or a draft."
    }

    @ViewBuilder private var actions: some View {
        if setup.running {
            BusyLine("Setting up Workbench…", tone: .working)
        } else {
            HStack(spacing: Space.s) {
                Button(setup.failure == nil ? "Set up Workbench" : "Try again") { Task { await store.initializeProject() } }
                    .primaryButton()
                Button("Not now") { store.skipSetup() }.plainButton(size: .regular)
                    .help("Leaves the folder as it is. Workbench needs setting up before it can work here.")
            }
        }
    }

    private static func id(_ provider: AgentProviderID?) -> String { provider?.rawValue ?? "none" }

    private static func segment(_ provider: AgentProviderID?) -> SwitchSegment {
        let title = provider.map(AgentSetup.name) ?? "None"
        return SwitchSegment(
            id: id(provider), title: title, accessibility: provider == nil ? "No goal agent" : "Goal agent \(title)")
    }
}
