import SwiftUI
import WorkbenchCore

/// The rail (design parity 4): one list, *Threads* with a `+`, then *Scheduled* with the project's tasks.
/// There is no Thread/Tasks switch: choosing a row shows that thread or that task.
struct PreviewRail: View {
    var store: ProjectStore
    static let width: CGFloat = 288

    var body: some View {
        let snapshot = store.tasks.snapshot(for: store.project)
        let inbox = InboxModel.derive(
            listing: store.threads.listing, tasks: snapshot, composing: store.newThread, shown: store.railShown,
            doneOpen: store.doneOpen)
        let model = RailModel.derive(tasks: snapshot)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxs) {
                inboxHeader
                if store.threads.syncing {
                    BusyLine("Syncing with GitHub…").padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                }
                if inbox.listed.isEmpty && inbox.composing == nil && inbox.finishedCount == 0 {
                    EmptyNote(store.project == nil ? "Choose a project to see its threads." : "No threads yet.", size: .small)
                } else {
                    InboxView(store: store, model: inbox)
                }
                header(model.scheduledHeader).padding(.top, Space.m)
                if let note = model.scheduledNote {
                    Text(note).role(.caption).padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                    if model.tasksRead {
                        // No row to choose: this is the way to the Tasks page, which says where tasks are made and what the timer is doing.
                        Button("Open the Tasks page") { store.showTasks() }
                            .buttonStyle(.link).textStyle(.caption).padding(.horizontal, Space.s)
                            .accessibilityLabel("Open the Tasks page").help("Where tasks are made, and what the timer is doing")
                    }
                }
                let shownTask = shownTaskName
                ForEach(model.tasks) { row in
                    RailRowView(row: row, selected: row.key == shownTask) { store.selectTask(row.key) }
                }
                // The one way in from the rail, besides File ▸ New Task… (⇧⌘N): the `+` above is for threads, so there is one of it.
                Button("New task…") { store.beginNewTask() }
                    .buttonStyle(.link).textStyle(.caption).padding(.horizontal, Space.s).padding(.top, Space.xs)
                    .disabled(store.project == nil).accessibilityLabel("New task").help("Make a scheduled task (⇧⌘N)")
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.m)
            // One focus stop for the whole rail, so the arrows walk the threads and on into the tasks instead of stopping at the section edge.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard direction == .up || direction == .down else { return }
                move(up: direction == .up, inbox: inbox, model: model)
            }
        }
        // The tasks are read while the rail is on screen, as the Tasks screen did while it was: the section is never stale for long.
        .task(id: store.project?.root.path) {
            var first = true
            while !Task.isCancelled {
                if first { await store.refreshAgentSetup() }
                await store.tasks.refreshIfDue(store.project, visible: true, force: first)
                first = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The row above or below the one shown, threads first and then tasks; nil at either end or when none is shown.
    private func move(up: Bool, inbox: InboxModel, model: RailModel) {
        let ids = inbox.threadRows.map { "t:" + $0.key } + model.tasks.map { "k:" + $0.key }
        var shown: String?
        if let task = shownTaskName {
            shown = "k:" + task
        } else if store.mode == .thread, !store.newThread, let thread = shownThreadID {
            shown = "t:" + thread
        }
        guard let next = InboxModel.neighbour(of: shown, in: ids, up: up) else { return }
        let key = String(next.dropFirst(2))
        if next.hasPrefix("t:") {
            Task { await store.select(thread: key) }
        } else {
            store.selectTask(key)
        }
    }

    private var shownThreadID: String? {
        if case .thread(let snapshot) = store.screen { return snapshot.id }
        return nil
    }

    /// The task on screen, when a task is: the highlighted row. The first one the Tasks screen would pick when none was chosen.
    private var shownTaskName: String? {
        guard store.mode == .tasks, !store.newThread, let snapshot = store.tasks.snapshot(for: store.project) else { return nil }
        return store.tasks.selected(in: snapshot)?.id
    }

    /// `INBOX · PROJECT` with the way to a new goal and to the project's agents (the run role's name is its tooltip).
    private var inboxHeader: some View {
        header("INBOX · " + (store.project?.root.lastPathComponent.uppercased() ?? "")) {
            if store.mode == .thread {
                let help = AgentSetup.runLabel(store.agentSetup)
                IconButton.raised("cpu", "Agents", help: help, size: .small) { store.showAgents() }
                    .disabled(store.project == nil)
            }
            IconButton.raised("plus", "New goal", help: "New goal…", size: .small) { store.beginNewGoal() }
                .disabled(store.project == nil)
        }
    }

    private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack {
            Text(title).textStyle(.captionStrong, .secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, Space.s).padding(.bottom, Space.xs)
    }
}
