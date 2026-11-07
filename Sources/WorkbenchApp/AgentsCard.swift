import SwiftUI
import WorkbenchCore

/// The Agents card over a light veil: a click on the veil closes it.
struct AgentsLayer: View {
    var store: ProjectStore

    var body: some View {
        ZStack {
            if store.showingAgents {
                Color.black.opacity(0.12).contentShape(Rectangle())
                    .onTapGesture { store.showingAgents = false }.transition(.opacity)
                AgentsCard(store: store).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.showingAgents)
        .accessibilityAddTraits(store.showingAgents ? .isModal : [])
    }
}

/// Each agent role of the open project and what it is set to. Read-only: a role is changed in `.workbench/config.toml` for now.
struct AgentsCard: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                SectionLabel("Agents".uppercased())
                Spacer()
                Button { store.showingAgents = false } label: { Image(systemName: "xmark").textStyle(.captionStrong) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close the agents panel")
            }
            if let setup = store.agentSetup {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(setup.rows) { row in AgentRow(row: row) }
                }
            } else {
                Text("This project's config could not be read.").role(.detail)
            }
            Divider()
            Text("Set in .workbench/config.toml, under [agents.<role>]. A role with no table runs its provider's default.")
                .role(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.l)
        .frame(width: 460)
        .card(.popover)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .onExitCommand { store.showingAgents = false }
        .task { await store.refreshAgentSetup() }
    }
}

/// One role: its name and what it does, and the provider and model it runs (or that it is off).
struct AgentRow: View {
    var row: AgentSetup.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(row.role.rawValue.capitalized).textStyle(.calloutStrong)
                Text(row.role.summary).role(.caption)
            }
            Spacer(minLength: Space.m)
            VStack(alignment: .trailing, spacing: Space.xs) {
                if let label = row.label {
                    Text(label).textStyle(.callout)
                    Text(detail).role(.caption)
                } else {
                    Text("Off").textStyle(.callout, .secondary)
                    Text(detail).role(.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Where the setting came from, with the effort when one is set.
    private var detail: String {
        switch row.source {
        case .off: return row.role == .goal ? "no [agents.goal]: chat and drafting are off" : "turned off in the config"
        case .providerDefault: return "provider default"
        case .configured: return row.reasoningEffort.map { "set in the config · effort \($0)" } ?? "set in the config"
        }
    }
}
