import AppKit
import SwiftUI
import WorkbenchCore

/// The goal, read-only: the file is the source of truth and the editor is the person's own.
struct GoalView: View {
    var snapshot: ThreadSnapshot
    var goal: GoalModel
    var store: ProjectStore
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !goal.blockers.isEmpty { blockers }
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
        .sheet(isPresented: $naming) { newGoalSheet }
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
                Button("Open in editor") {
                    if let url = store.goalFileURL(snapshot.id) { NSWorkspace.shared.open(url) }
                }
                Button("New goal…") { naming = true }
                Spacer()
                if goal.pill != .approved || snapshot.state.lastTurn == 0, snapshot.state.decision == nil {
                    Button(goal.pill == .approved ? "Run" : "Approve and run") {
                        Task { await store.approveAndRun() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!goal.canApprove || store.starting || snapshot.state.lastTurn > 0)
                }
            }
            if goal.pill != .approved { Text("Nothing runs until you approve.").font(.caption).foregroundStyle(.secondary) }
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
        }
        .padding(.top, 6)
    }

    private var newGoalSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New goal").font(.headline)
            TextField("Thread name", text: $name).textFieldStyle(.roundedBorder).frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { naming = false }
                Button("Create") {
                    let chosen = name
                    naming = false
                    name = ""
                    Task { await store.newGoal(name: chosen) }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
