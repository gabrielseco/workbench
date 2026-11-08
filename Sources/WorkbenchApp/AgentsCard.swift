import SwiftUI
import WorkbenchCore

/// Each agent role of the project the card was opened for and what it is set to, with a provider, an effort and a model to change (written to
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
            if let setup = store.cardAgentSetup {
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(setup.rows) { row in
                        // The verifier's model is not an agent key; a key a stage decides is locked in its row.
                        AgentRow(row: row, edit: row.role == .verifier ? nil : edit)
                    }
                }
            } else if store.cardAgentConfig == .missing {
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
        // What an edit said is for the card: it is not left on the screen behind it.
        .onDisappear { (store.actionError, store.actionNote) = (nil, nil) }
        .task {
            store.actionError = nil
            store.actionNote = nil
            await store.refreshCardAgents()
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
    /// `Other…` was chosen: the text field is shown for a name the menu does not have.
    @State private var other = false
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
                    modelMenu
                    if other { modelField }
                    Spacer(minLength: Space.s)
                    Text(detail).role(.caption)
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
        // What is being typed is not replaced by a write that finished meanwhile.
        .onChange(of: row.model) {
            if !typing { model = row.model ?? "" }
            other = false
        }
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
            .disabled(row.lockedFields.contains(.provider))
            Picker("Effort", selection: effortChoice) {
                Text("Default effort").tag(Self.providerDefault)
                ForEach(AgentSetup.efforts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize().accessibilityLabel("\(row.role.rawValue.capitalized) effort")
            .disabled(row.provider == nil || row.lockedFields.contains(.reasoningEffort))
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

    /// The provider's models, then `Other…`; a model the config has that no list does is shown too, so what is set is always selected.
    private var modelMenu: some View {
        let options = AgentModelMenu.options(row.modelOptions, including: row.model)
        return Picker("Model", selection: modelChoice) {
            Text("Default model").tag(AgentModelMenu.defaultTag)
            ForEach(options, id: \.self) { Text($0).tag($0) }
            Divider()
            Text("Other…").tag(AgentModelMenu.otherTag)
        }
        // A long name is cut in the picker and whole in the menu: it never pushes the row past the card.
        .labelsHidden().frame(maxWidth: 220, alignment: .leading).accessibilityLabel("\(row.role.rawValue.capitalized) model")
        .disabled(row.provider == nil || row.lockedFields.contains(.model))
    }

    private var modelChoice: Binding<String> {
        Binding(
            get: { AgentModelMenu.selection(model: row.model, other: other) },
            set: { tag in
                switch AgentModelMenu.choice(for: tag) {
                case .other:
                    other = true
                    typing = true
                case .defaultModel:
                    other = false
                    if row.model != nil { Task { _ = await edit?.set(row.role, .model, nil) } }
                case .name(let name):
                    other = false
                    if name != row.model { Task { _ = await edit?.set(row.role, .model, name) } }
                }
            })
    }

    private var modelField: some View {
        TextInput(
            "Model name", text: $model, look: .filled, style: .callout, dense: true,
            label: "\(row.role.rawValue.capitalized) other model", focus: $typing
        )
        .disabled(row.provider == nil || row.lockedFields.contains(.model))
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
            let written = await edit?.set(row.role, .model, typed.isEmpty ? nil : typed)
            if written == false, model.trimmingCharacters(in: .whitespaces) == typed { model = was }
        }
    }

    /// The model name looks like another provider's: said on the row, with the way back to the default.
    private var fitNote: String? { AgentModelMenu.fitNote(provider: row.provider, model: row.model) }

    /// Where the setting came from, with the effort when one is set.
    private var detail: String {
        if let table = row.lockedBy {
            let keys = row.lockedFields.map(\.rawValue).sorted().joined(separator: ", ")
            return "\(keys) set by \(table): change it in the config"
        }
        switch row.source {
        case .off: return row.role == .goal ? "no [agents.goal]: chat and drafting are off" : "turned off in the config"
        case .providerDefault: return "provider default"
        case .configured: return row.reasoningEffort.map { "set in the config · effort \($0)" } ?? "set in the config"
        }
    }
}

/// What the model menu lists and what choosing a line means (pure, so the rules are tested without a window).
enum AgentModelMenu {
    static let defaultTag = ""
    static let otherTag = "\u{1}other"

    enum Choice: Equatable {
        case defaultModel
        case other
        case name(String)
    }

    static func choice(for tag: String) -> Choice {
        tag == defaultTag ? .defaultModel : tag == otherTag ? .other : .name(tag)
    }

    /// The tag of the line shown as selected: `Other…` while it is open, else the role's model (or the default).
    static func selection(model: String?, other: Bool) -> String { other ? otherTag : (model ?? defaultTag) }

    /// The provider's names, with the role's own model added when no list has it.
    static func options(_ options: [String], including model: String?) -> [String] {
        guard let model, !options.contains(model) else { return options }
        return options + [model]
    }

    /// The warning for a model whose name belongs to the other provider, or nil.
    static func fitNote(provider: AgentProviderID?, model: String?) -> String? {
        guard let provider, let model, let other = AgentSetup.modelFit(provider: provider, model: model) else { return nil }
        return "'\(model)' looks like a \(AgentSetup.name(other)) model, and this role runs on \(AgentSetup.name(provider))."
    }
}
