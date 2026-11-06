import SwiftUI
import WorkbenchCore

/// *Edit with AI* on a task's page: a request in plain words, then what the agent proposed as what it changes, to accept or discard.
/// The live file is never written until Accept, and Accept never approves: an approved task reads stale and is approved again.
struct TaskEditCard: View {
    var store: ProjectStore
    var entry: TaskEntry
    @FocusState private var focused: Bool

    var body: some View {
        let tasks = store.tasks
        let state = tasks.editing(entry.id, in: store.project)
        VStack(alignment: .leading, spacing: Space.m) {
            SectionLabel("EDIT WITH AI")
            switch state?.phase {
            case .working?:
                HStack(spacing: Space.m) {
                    BusyBar(text: "Asking the agent for a new task.md. Nothing is written until you accept it.")
                    Button("Stop") { tasks.stopEdit() }.plainButton(size: .compact)
                }
            case .proposed(let proposal, let cost)?:
                Proposal(proposal: proposal, cost: cost, store: store)
            case .failed(let why)?:
                Text(why).role(.error).textSelection(.enabled)
                Button("Try again") { tasks.discardEdit() }.plainButton(size: .compact)
            case nil:
                request(tasks)
            }
        }
        .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onChange(of: store.tasks.editFocus) { focused = true }
        .task {
            // A field that has just appeared is not yet in the window: focus set at once is lost.
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
        }
    }

    @ViewBuilder private func request(_ tasks: TasksModel) -> some View {
        let off = tasks.editUnavailable(entry)
        PlaceholderTextEditor(
            text: Binding(get: { tasks.editRequest }, set: { tasks.editRequest = $0 }),
            placeholder: "What should change? For example: run at 9 on weekdays, or skip the vendor folder.", style: .body,
            accessibilityLabel: "What to change in this task", focus: $focused
        )
        .frame(minHeight: 56, maxHeight: 140)
        HStack(spacing: Space.m) {
            Button("Propose") { Task { await tasks.proposeEdit(store.project, entry) } }
                .primaryButton(size: .compact)
                .disabled(off != nil || tasks.editRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(off ?? "Asks the goal agent for a new task.md and shows what it changes. Nothing is written yet.")
            if let limit = tasks.editLimit {
                Text("Costs \(limit). Read-only until you accept; accepting does not approve.").role(.caption)
            } else {
                Text("Needs a goal agent: set [agents.goal] in .workbench/config.toml, or edit the file by hand.").role(.caption)
            }
        }
    }
}

/// What one proposal changes: the settings approval binds to first, each as old → new, then the instructions as a diff.
private struct Proposal: View {
    var proposal: TaskProposal
    var cost: String
    var store: ProjectStore

    var body: some View {
        let changes = proposal.changes
        VStack(alignment: .leading, spacing: Space.m) {
            Text(changes.isEmpty ? "The agent changed nothing (\(cost))." : "Proposed (\(cost)). Nothing is written yet.")
                .textStyle(.calloutStrong)
            if !changes.settings.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("SETTINGS APPROVAL BINDS TO").textStyle(.captionStrong, .secondary)
                    ForEach(Array(changes.settings.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text(change.key).textStyle(.mono, .secondary)
                            Text(change.old ?? "not set").textStyle(.mono, .red).strikethrough(change.old != nil)
                            Image(systemName: "arrow.right").textStyle(.captionMedium, .secondary)
                            Text(change.new ?? "not set").textStyle(.mono, .green)
                        }
                    }
                }
            }
            if changes.instructionsChanged {
                VStack(alignment: .leading, spacing: 0) {
                    Text("INSTRUCTIONS").textStyle(.captionStrong, .secondary).padding(.bottom, Space.xs)
                    ForEach(Array(changes.instructions.enumerated()), id: \.offset) { _, line in
                        Text("\(mark(line.kind)) \(line.text)").textStyle(.mono, tone(line.kind)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack(spacing: Space.m) {
                if !changes.isEmpty {
                    Button("Accept") { Task { await store.tasks.acceptEdit(store.project) } }.primaryButton(size: .compact)
                        .help("Writes this as task.md. The task then needs approving again.")
                }
                Button("Discard") { store.tasks.discardEdit() }.plainButton(size: .compact)
            }
        }
    }

    private func mark(_ kind: TaskDiffLine.Kind) -> String {
        switch kind {
        case .same: " "
        case .added: "+"
        case .removed: "-"
        }
    }

    private func tone(_ kind: TaskDiffLine.Kind) -> TextTone {
        switch kind {
        case .same: .secondary
        case .added: .green
        case .removed: .red
        }
    }
}
