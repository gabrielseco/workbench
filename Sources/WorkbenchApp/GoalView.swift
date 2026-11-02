import AppKit
import SwiftUI
import WorkbenchCore

/// The goal as blocks. While it is a draft each block is changed in place (core's `GoalEditor` writes the file); once it is
/// approved the same blocks are read-only, since the thread is then in another step. `Open in editor` stays for anything else.
struct GoalView: View {
    var snapshot: ThreadSnapshot
    var goal: GoalModel
    var store: ProjectStore
    @State private var addingFolder = false

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
            GoalBlocks(goal: goal, store: store, editable: editable)
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
                                            edit { $0.removingReadAlso(folder) }
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
                                    edit { $0.addingReadAlso(text) }
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
                    let on = !step.skipped && step.unavailable == nil
                    Button {
                        edit { $0.togglingSkip(step.name) }
                    } label: {
                        Label(step.label, systemImage: on ? "checkmark.circle.fill" : "circle")
                            .font(.callout)
                            .foregroundStyle(!step.known ? Theme.red : on ? Theme.green : Theme.grey)
                    }
                    .buttonStyle(.bordered).disabled(!editable || step.unavailable != nil)
                    .help(
                        step.unavailable.map { "Not available: \($0)" }
                            ?? (step.known ? (on ? "Runs after a turn" : "Skipped for this goal") : "Not a step of this project"))
                }
            }
            ForEach(goal.steps.filter { $0.unavailable != nil }, id: \.name) { step in
                Text("\(step.label) not available: \(step.unavailable ?? "")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        store.goalRunDisabled(snapshot, goal: goal)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Open in editor") { Task { await store.openGoalFile() } }
                Button("New goal…") { store.namingGoal = true }
                // Opens only, nothing approved or started: the project's checkout until the thread has a worktree.
                if store.herdrFound {
                    Button("Open in Herdr") { Task { await store.openInHerdr() } }.disabled(store.busy != nil)
                        .help("Herdr opens this thread's worktree, or the project when it has none, without starting anything")
                }
                Spacer()
                if goal.pill != .approved || snapshot.state.lastTurn == 0, snapshot.state.decision == nil {
                    // Shown with no Herdr found too: pressing it then says Herdr is unavailable rather than hiding why it is missing.
                    Button(goal.pill == .approved ? "Run in Herdr" : "Approve and run in Herdr") {
                        Task { await store.runGoalInHerdr() }
                    }
                    .disabled(runDisabled)
                    .help("Approves the goal, cuts the worktree and starts a Claude session on it in Herdr")
                    Button(goal.pill == .approved ? "Run" : "Approve and run") {
                        Task { await store.approveAndRun() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runDisabled)
                }
            }
            if goal.pill != .approved { Text("Nothing runs until you approve.").font(.caption).foregroundStyle(.secondary) }
            if let handoff = store.herdrHandoffOutcome {
                Text(handoff.text).font(.callout).foregroundStyle(handoff.isProblem ? Theme.red : Theme.green)
            }
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
            if let note = store.actionNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.top, 6)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GoalSection(title: title, content: content)
    }
}
