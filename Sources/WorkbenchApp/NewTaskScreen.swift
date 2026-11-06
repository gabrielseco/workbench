import SwiftUI
import WorkbenchCore

/// A task that does not exist yet: a name and what it should do in words. The goal agent proposes the file, the person reads what would be
/// created and accepts or discards; without an agent, `Create empty task` makes the template `workbench task new` makes. Creating
/// approves nothing: the new task's page opens with its Approve button.
struct NewTaskScreen: View {
    var store: ProjectStore
    @FocusState private var nameFocused: Bool

    var body: some View {
        let tasks = store.tasks
        let phase = tasks.draft(in: store.project)?.phase ?? .idle
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(alignment: .top, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("New task").textStyle(.section)
                        Text("Work done on a schedule, with nobody at the keyboard. You read the file before it is made.")
                            .role(.detail)
                    }
                    Spacer(minLength: Space.s)
                    Button("Cancel") { tasks.cancelNew() }.plainButton(size: .regular).disabled(phase == .working)
                }
                switch phase {
                case .working:
                    HStack(spacing: Space.m) {
                        BusyBar(text: "Asking the agent for the task. Nothing is created until you accept it.")
                        Button("Stop") { tasks.stopEdit() }.plainButton(size: .compact)
                    }
                case .proposed(let proposal, let cost):
                    VStack(alignment: .leading, spacing: Space.m) {
                        SectionLabel("PROPOSED: \(proposal.task)")
                        TaskProposalView(
                            proposal: proposal, cost: cost,
                            accept: { Task { await create { await tasks.acceptNew($0) } } },
                            discard: { tasks.discardNew() })
                    }
                    .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading).card()
                case .idle, .failed:
                    if case .failed(let why) = phase { Text(why).role(.error).textSelection(.enabled) }
                    fields(tasks)
                }
            }
            .frame(maxWidth: FeedLayout.maxColumn, alignment: .leading)
            .padding(.horizontal, Spacing.gutter).padding(.vertical, Space.xl).frame(maxWidth: .infinity)
        }
        .task {
            // A field that has just appeared is not yet in the window: focus set at once is lost.
            try? await Task.sleep(for: .milliseconds(40))
            nameFocused = true
        }
    }

    /// Makes the task and shows its page, only if this project is still the one on screen: the refresh that follows can take seconds, and
    /// a project chosen meanwhile is not taken to another project's task.
    private func create(_ make: (Project?) async -> String?) async {
        let started = store.project
        guard let name = await make(started), store.project?.root.path == started?.root.path else { return }
        store.selectTask(name)
    }

    @ViewBuilder private func fields(_ tasks: TasksModel) -> some View {
        let draft = tasks.draft(in: store.project) ?? NewTaskDraft()
        let check = tasks.nameCheck(draft.name, in: store.project)
        let off = tasks.proposeNewUnavailable(in: store.project)
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("NAME")
            TextField("weekly-todos", text: Binding(get: { draft.name }, set: { tasks.creating?.name = $0 }))
                .textFieldStyle(.roundedBorder).textStyle(.mono).focused($nameFocused)
                .accessibilityLabel("Name of the new task")
            if let message = check.message { Text(message).role(.error) }
        }
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("WHAT IT SHOULD DO")
            PlaceholderTextEditor(
                text: Binding(get: { draft.request }, set: { tasks.creating?.request = $0 }),
                placeholder: "What should it do, and when? For example: every weekday at 9, list the open TODOs and report them.",
                style: .body, accessibilityLabel: "What the new task should do"
            )
            .frame(minHeight: 96, maxHeight: 200).padding(Space.s).card()
        }
        HStack(spacing: Space.m) {
            Button("Propose") { Task { await tasks.proposeNew(store.project) } }
                .primaryButton(size: .regular).disabled(off != nil)
                .help(off ?? "Asks the goal agent for the task file and shows what it would create. Nothing is made yet.")
            Button("Create empty task") { Task { await create { await tasks.createEmpty($0) } } }
            .plainButton(size: .regular).disabled(check != .ok)
            .help("Makes the template `workbench task new` makes; you write the instructions by hand")
        }
        if let limit = tasks.editLimit {
            Text("Propose costs \(limit). Read-only until you accept; accepting does not approve.").role(.caption)
        } else {
            Text("Propose needs a goal agent: set [agents.goal] in .workbench/config.toml. Create empty task needs none.")
                .role(.caption)
        }
    }
}
