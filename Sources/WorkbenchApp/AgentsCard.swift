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
        // What an edit said is for the card: it is not left on the screen behind it.
        .onChange(of: store.showingAgents) {
            if !store.showingAgents { (store.actionError, store.actionNote) = (nil, nil) }
        }
    }
}

/// Each agent role of the open project and what it is set to, with a provider, an effort and a model to change (written to
/// `.workbench/config.toml` through `ConfigEdit`, as `workbench config set` does). The verifier's model is read-only here.
struct AgentsCard: View {
    var store: ProjectStore

    private var edit: AgentEdit {
        AgentEdit(
            set: { role, field, value in await store.setAgent(role, field, to: value) },
            goalOff: { await store.turnGoalAgentOff() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                SectionLabel("Agents".uppercased())
                Spacer()
                Button { store.showingAgents = false } label: { Image(systemName: "xmark").textStyle(.captionStrong) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close the agents panel")
            }
            if let setup = store.agentSetup {
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(setup.rows) { row in AgentRow(row: row, edit: row.role == .verifier ? nil : edit) }
                }
            } else if store.agentConfigMissing {
                Text(
                    "This project has no .workbench/config.toml, so every role runs its provider's default and there is no goal "
                        + "agent: chat and drafting are off. Run `workbench init` to make one, then change the roles here."
                )
                .role(.detail).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This project's config could not be read.").role(.detail)
            }
            if let error = store.actionError {
                Text(error).role(.error).fixedSize(horizontal: false, vertical: true)
            } else if let note = store.actionNote {
                Text(note).role(.warning).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Changes are written to .workbench/config.toml, under [agents.<role>]; the rest of the file is left as it is.")
                .role(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.l)
        .frame(width: 560)
        .card(.popover)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .onExitCommand { store.showingAgents = false }
        .task {
            store.actionError = nil
            store.actionNote = nil
            await store.refreshAgentSetup()
        }
    }
}

/// What a row can change: one key of its role (a nil value removes it), and the goal agent off.
struct AgentEdit {
    /// Each says whether it was written: a refusal leaves the field on what the file has.
    var set: (AgentSetup.Role, ConfigEdit.Field, String?) async -> Bool
    var goalOff: () async -> Bool
}

/// One role: its name and what it does, and the provider, effort and model it runs. Without `edit` it only reads.
struct AgentRow: View {
    var row: AgentSetup.Row
    var edit: AgentEdit?
    @State private var model = ""
    @FocusState private var typing: Bool

    private static let off = "off"
    private static let providerDefault = "default"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(row.role.rawValue.capitalized).textStyle(.calloutStrong)
                    Text(row.role.summary).role(.caption)
                }
                Spacer(minLength: Space.m)
                if edit != nil { pickers } else { reading }
            }
            if edit != nil {
                HStack(spacing: Space.s) {
                    modelField
                    Text(detail).role(.caption).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if let note = fitNote, let edit {
                HStack(spacing: Space.s) {
                    Text(note).role(.warning).fixedSize(horizontal: false, vertical: true)
                    Button("Use default model") { Task { _ = await edit.set(row.role, .model, nil) } }.plainButton(size: .small)
                }
            }
        }
        .onAppear { model = row.model ?? "" }
        .onChange(of: row.model) { model = row.model ?? "" }
    }

    /// The read-only form: what runs, and where the setting came from.
    private var reading: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            Text(row.label ?? "Off").textStyle(.callout, row.label == nil ? .secondary : .primary)
            Text(detail).role(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    private var pickers: some View {
        HStack(spacing: Space.s) {
            Picker("Provider", selection: providerChoice) {
                if row.role == .goal { Text("Off").tag(Self.off) }
                ForEach(AgentSetup.providers, id: \.rawValue) { Text(AgentSetup.name($0)).tag($0.rawValue) }
            }
            .labelsHidden().fixedSize().accessibilityLabel("\(row.role.rawValue.capitalized) provider")
            Picker("Effort", selection: effortChoice) {
                Text("Default effort").tag(Self.providerDefault)
                ForEach(AgentSetup.efforts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize().accessibilityLabel("\(row.role.rawValue.capitalized) effort")
            .disabled(row.provider == nil)
        }
    }

    private var providerChoice: Binding<String> {
        Binding(
            get: { row.provider?.rawValue ?? Self.off },
            set: { choice in
                if choice == Self.off {
                    Task { _ = await edit?.goalOff() }
                } else if choice != row.provider?.rawValue || row.source != .configured {
                    Task { _ = await edit?.set(row.role, .provider, choice) }
                }
            })
    }

    private var effortChoice: Binding<String> {
        Binding(
            get: { row.reasoningEffort ?? Self.providerDefault },
            set: { choice in
                guard choice != (row.reasoningEffort ?? Self.providerDefault) else { return }
                Task { _ = await edit?.set(row.role, .reasoningEffort, choice == Self.providerDefault ? nil : choice) }
            })
    }

    private var modelField: some View {
        TextField("Default model", text: $model)
            .textFieldStyle(.plain).focused($typing).textStyle(.callout)
            .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
            .background(Theme.grey.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.box))
            .disabled(row.provider == nil)
            .accessibilityLabel("\(row.role.rawValue.capitalized) model")
            .onSubmit(commitModel)
            .onChange(of: typing) { if !typing { commitModel() } }
    }

    /// A blank field is the provider's default model.
    private func commitModel() {
        let typed = model.trimmingCharacters(in: .whitespaces)
        guard typed != (row.model ?? "") else { return }
        let was = row.model ?? ""
        Task {
            // A refused name is not left in the field: it goes back to what the file has.
            if await edit?.set(row.role, .model, typed.isEmpty ? nil : typed) == false { model = was }
        }
    }

    /// The model name looks like another provider's: said on the row, with the way back to the default.
    private var fitNote: String? {
        guard let provider = row.provider, let model = row.model,
            let other = AgentSetup.modelFit(provider: provider, model: model)
        else { return nil }
        return "'\(model)' looks like a \(AgentSetup.name(other)) model, and this role runs on \(AgentSetup.name(provider))."
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
