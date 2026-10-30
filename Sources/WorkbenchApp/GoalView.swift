import AppKit
import SwiftUI
import WorkbenchCore

/// The goal as blocks. While it is a draft each block is changed in place (core's `GoalEditor` writes the file); once it is
/// approved the same blocks are read-only, since the thread is then in another step. `Open in editor` stays for anything else.
struct GoalView: View {
    var snapshot: ThreadSnapshot
    var goal: GoalModel
    var store: ProjectStore
    @State private var addingCriterion = false
    @State private var addingScope = false
    @State private var addingFolder = false
    @State private var showAllRequest = false

    private var editable: Bool { goal.editable && !store.starting && !store.runningHere && store.busy == nil }

    private var mono: Font { .system(.callout, design: .monospaced) }

    /// A read-only request this long is folded; while editing it is shown whole.
    private var longRequest: Bool { goal.request.count > 500 }

    private func edit(_ change: GoalEdit) { Task { await store.editGoal(change) } }

    /// An edit built from the goal as it is when it runs, for a change to a list or the switches.
    private func edit(_ make: @escaping @MainActor (GoalModel) -> GoalEdit?) { Task { await store.editGoal(make) } }

    var body: some View { ScrollView { content } }

    /// The blocks, apart from the scroll view (which `ImageRenderer` cannot draw), so a test can render them.
    var content: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            if !goal.blockers.isEmpty { blockers }
            if goal.placeholdersRemain {
                Label("Replace every TODO(workbench), then approve.", systemImage: "pencil")
                    .font(.callout).foregroundStyle(Theme.amber)
            }
            request
            criteria
            outOfScope
            folders
            afterTheTurn
            if !goal.model.isEmpty { limits }
            if let error = store.goalEditError {
                Label(error, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(Theme.red)
            }
            actions
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 56).frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.goalEditSerial, store.goalEditSerial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(goal.title.isEmpty ? snapshot.id : goal.title).font(.title.weight(.bold))
                Spacer()
                Text(goal.pill.text)
                    .font(.callout).padding(.horizontal, 10).padding(.vertical, 3)
                    .foregroundStyle(pillTint).background(pillTint.opacity(0.12), in: Capsule())
            }
            Text(goal.path).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private var pillTint: Color {
        switch goal.pill {
        case .approved: Theme.green
        case .draft: Theme.grey
        case .changedSinceApproval: Theme.amber
        }
    }

    private var blockers: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(goal.blockers, id: \.self) {
                Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.red).font(.callout)
            }
        }
    }

    private var request: some View {
        section("Request") {
            GoalCard {
                if editable {
                    CommitEditor(value: goal.request) { edit(.setRequest($0)) }
                } else {
                    Text(goal.request).font(.system(size: 16, design: .serif)).lineSpacing(5).textSelection(.enabled)
                        .lineLimit(longRequest && !showAllRequest ? 6 : nil)
                    if longRequest {
                        Button(showAllRequest ? "Show less" : "Show more") { showAllRequest.toggle() }
                            .buttonStyle(.borderless).font(.callout)
                    }
                }
            }
        }
    }

    private var criteria: some View {
        section("Criteria · \(goal.checkableText)") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(goal.rows, id: \.id) { row in
                    GoalCard { criterion(row) }
                }
                if editable {
                    if addingCriterion {
                        NewCriterionCard { text, proof in
                            edit(.addCriterion(text: text, proof: proof))
                            addingCriterion = false
                        } cancel: { addingCriterion = false }
                    } else {
                        Button("+ criterion") { addingCriterion = true }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func criterion(_ row: GoalModel.Row) -> some View {
        HoverRow { hovering in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.id).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    if editable {
                        CommitField(placeholder: "What must hold", value: row.text) {
                            edit(.updateCriterion(id: row.id, text: $0, proof: nil))
                        }
                        HStack(spacing: 8) {
                            KindChip(kind: row.kind)
                            CommitField(
                                placeholder: "How it will be shown", value: row.proof, font: row.isCommand ? mono : .callout
                            ) { edit(.updateCriterion(id: row.id, text: nil, proof: $0)) }
                        }
                    } else {
                        Text(row.text)
                        HStack(spacing: 8) {
                            KindChip(kind: row.kind)
                            Text(row.proof).font(row.isCommand ? mono : .callout).foregroundStyle(.secondary)
                        }
                    }
                    if let warning = row.warning {
                        Label("Heads up: \(warning)", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if editable, goal.rows.count > 1 {
                    Spacer()
                    Button { edit(.removeCriterion(id: row.id)) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Remove \(row.id)").opacity(hovering ? 1 : 0.3)
                }
            }
        }
    }

    private var outOfScope: some View {
        section("Out of scope") {
            if !goal.outOfScope.isEmpty || editable {
                GoalCard {
                    ForEach(Array(goal.outOfScope.enumerated()), id: \.offset) { _, item in
                        HoverRow { hovering in
                            HStack(spacing: 10) {
                                if editable {
                                    Text("•")
                                    CommitField(placeholder: "What must not change", value: item) { new in
                                        edit { g in
                                            guard let at = g.outOfScope.firstIndex(of: item) else { return nil }
                                            var items = g.outOfScope
                                            items[at] = new
                                            return .setOutOfScope(items)
                                        }
                                    }
                                    Button {
                                        edit { g in
                                            guard let at = g.outOfScope.firstIndex(of: item) else { return nil }
                                            var items = g.outOfScope
                                            items.remove(at: at)
                                            return .setOutOfScope(items)
                                        }
                                    } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.borderless).help("Remove").opacity(hovering ? 1 : 0.3)
                                } else {
                                    Text("• \(item)")
                                }
                            }
                        }
                    }
                    if editable {
                        if addingScope {
                            NewLine(placeholder: "What must not change") { text in
                                edit { .setOutOfScope($0.outOfScope + [text]) }
                                addingScope = false
                            } cancel: { addingScope = false }
                        } else {
                            Button("+ out of scope") { addingScope = true }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    /// The project's `read_also` is shown as it is, read-only; the goal's own are changed here while it is a draft.
    private var folders: some View {
        let any = !goal.readAlso.isEmpty || !goal.goalReadAlso.isEmpty || editable
        return Group {
            if any {
                section("Reference folders · read-only for the run") {
                    GoalCard {
                        ForEach(goal.readAlso, id: \.self) { folder in
                            HStack {
                                Text(folder).font(.system(.callout, design: .monospaced))
                                Spacer()
                                Text("from project config").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(goal.goalReadAlso.enumerated()), id: \.offset) { _, folder in
                            HoverRow { hovering in
                                HStack(spacing: 10) {
                                    if editable {
                                        CommitField(placeholder: "../backend", value: folder, font: mono) { new in
                                            edit { g in
                                                guard let at = g.goalReadAlso.firstIndex(of: folder) else { return nil }
                                                var all = g.goalReadAlso
                                                all[at] = new
                                                return .setReadAlso(all)
                                            }
                                        }
                                        Button {
                                            edit { g in
                                                guard let at = g.goalReadAlso.firstIndex(of: folder) else { return nil }
                                                var all = g.goalReadAlso
                                                all.remove(at: at)
                                                return .setReadAlso(all)
                                            }
                                        } label: { Image(systemName: "xmark") }
                                            .buttonStyle(.borderless).help("Remove").opacity(hovering ? 1 : 0.3)
                                    } else {
                                        Text(folder).font(.system(.callout, design: .monospaced))
                                        Spacer()
                                        Text("this goal").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if editable {
                            if addingFolder {
                                NewLine(placeholder: "A git checkout: ../backend, ~/shared or an absolute path") { text in
                                    edit { .setReadAlso($0.goalReadAlso + [text]) }
                                    addingFolder = false
                                } cancel: { addingFolder = false }
                            } else {
                                Button("+ reference folder") { addingFolder = true }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
    }

    /// What runs after a turn; a switch turned off writes `skip:` for this goal only.
    private var afterTheTurn: some View {
        section("After the turn") {
            HStack {
                ForEach(goal.steps, id: \.name) { step in
                    let on = !step.skipped
                    Button {
                        edit { g in
                            let others = g.steps.filter { $0.skipped && $0.name != step.name }.map(\.name)
                            let now = g.steps.first { $0.name == step.name }?.skipped ?? false
                            return .setSkip(now ? others : others + [step.name])
                        }
                    } label: {
                        Label(step.label, systemImage: on ? "checkmark.circle.fill" : "circle")
                            .font(.callout)
                            .foregroundStyle(!step.known ? Theme.red : on ? Theme.green : Theme.grey)
                    }
                    .buttonStyle(.bordered).disabled(!editable)
                    .help(step.known ? (on ? "Runs after a turn" : "Skipped for this goal") : "Not a step of this project")
                }
            }
        }
    }

    private var limits: some View {
        section("Run limits") {
            Text("Model: \(goal.model) · Budget: \(goal.budget) · Timeout: \(goal.turnTimeout)").font(.callout)
            if !goal.allowedTools.isEmpty || !goal.grantedTools.isEmpty {
                let tools = goal.allowedTools + goal.grantedTools.map { "\($0) (granted)" }
                Text("Allowed tools: " + tools.joined(separator: ", "))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("Change these in the goal file.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var runDisabled: Bool {
        !goal.canApprove || store.starting || store.runningHere || store.busy != nil || snapshot.state.lastTurn > 0
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Open in editor") { Task { await store.openGoalFile() } }
                Button("New goal…") { store.namingGoal = true }
                Spacer()
                if goal.pill != .approved || snapshot.state.lastTurn == 0, snapshot.state.decision == nil {
                    Button(goal.pill == .approved ? "Run" : "Approve and run") {
                        Task { await store.approveAndRun() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runDisabled)
                }
            }
            if goal.pill != .approved { Text("Nothing runs until you approve.").font(.caption).foregroundStyle(.secondary) }
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
        }
        .padding(.top, 6)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
