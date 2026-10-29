import AppKit
import SwiftUI
import WorkbenchCore

/// The goal, read-only: the file is the source of truth and the editor is the person's own.
struct GoalView: View {
    var snapshot: ThreadSnapshot
    var goal: GoalModel
    var store: ProjectStore
    @State private var naming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !goal.blockers.isEmpty { blockers }
                if goal.placeholdersRemain {
                    Label("Replace every TODO(workbench) in the file, then approve.", systemImage: "pencil")
                        .font(.callout).foregroundStyle(Theme.amber)
                }
                if !goal.request.isEmpty { section("Request") { Text(goal.request) } }
                if !goal.rows.isEmpty { criteria }
                if !goal.outOfScope.isEmpty {
                    section("Out of scope") { ForEach(goal.outOfScope, id: \.self) { Text("• \($0)") } }
                }
                if !goal.model.isEmpty { limits }
                actions
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $naming) { NewGoalSheet(store: store, shown: $naming) }
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

    private var criteria: some View {
        section("Criteria · \(goal.checkableText)") {
            ForEach(goal.rows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.id).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Text(row.text)
                    }
                    Text(row.proof).font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.grey.opacity(0.12), in: Capsule())
                    if let warning = row.warning {
                        Label("Heads up: \(warning)", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Theme.amber)
                    }
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

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Open in editor") { Task { await store.openGoalFile() } }
                Button("New goal…") { naming = true }
                Spacer()
                if goal.pill != .approved || snapshot.state.lastTurn == 0, snapshot.state.decision == nil {
                    Button(goal.pill == .approved ? "Run" : "Approve and run") {
                        Task { await store.approveAndRun() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!goal.canApprove || store.starting || store.runningHere || snapshot.state.lastTurn > 0)
                }
            }
            if goal.pill != .approved { Text("Nothing runs until you approve.").font(.caption).foregroundStyle(.secondary) }
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
        }
        .padding(.top, 6)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Asks what needs to be done and has the goal agent draft the goal from it. The sheet stays open while it drafts, and keeps
/// the text when the draft does not come out.
struct NewGoalSheet: View {
    var store: ProjectStore
    @Binding var shown: Bool
    @State private var request = ""
    @State private var name = ""
    @State private var showName = false
    @FocusState private var focused: Bool

    private var empty: Bool { request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New goal in \(store.project?.root.lastPathComponent ?? "this project")").font(.headline)
            Text("What needs to be done?").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $request)
                .font(.body).focused($focused).scrollContentBackground(.hidden)
                .padding(6).frame(width: 460, height: 160)
                .background(Theme.grey.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .disabled(store.drafting)
                .overlay(alignment: .topLeading) {
                    if request.isEmpty {
                        Text("Describe the change, the bug or the idea. Say how you will know it worked.")
                            .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 14).allowsHitTesting(false)
                    }
                }
            DisclosureGroup("Thread name", isExpanded: $showName) {
                TextField(ThreadName.suggest(from: request), text: $name).textFieldStyle(.roundedBorder).frame(width: 280)
                    .disabled(store.drafting)
            }
            .font(.callout)
            if store.goalAgentOff {
                Text(
                    "Drafting needs a goal agent, and this project's config names none. Pick who drafts: it adds "
                        + "[agents.goal] to .workbench/config.toml and drafts this goal."
                )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let error = store.actionError {
                Text(error).font(.callout).foregroundStyle(Theme.red)
            }
            HStack {
                if store.drafting {
                    ProgressView().controlSize(.small)
                    Text("Drafting the goal…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if store.drafting {
                    Button("Stop") { store.stopDrafting() }
                } else {
                    Button("Cancel") { shown = false }
                    if store.goalAgentOff {
                        ForEach([AgentProviderID.claude, .codex], id: \.rawValue) { provider in
                            Button("Draft with \(provider.rawValue.capitalized)") {
                                Task {
                                    if await store.enableGoalDrafting(provider, request: request, name: name) { shown = false }
                                }
                            }
                        }
                    } else {
                        Button("Create") {
                            Task { if await store.draftGoal(request: request, name: name) { shown = false } }
                        }
                        .keyboardShortcut(.return, modifiers: .command).disabled(empty)
                    }
                }
            }
        }
        .padding(20)
        .onAppear {
            focused = true
            store.actionError = nil
        }
    }
}
