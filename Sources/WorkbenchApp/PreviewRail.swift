import SwiftUI
import WorkbenchCore

/// The rail (design parity 4): one list, *Threads* with a `+`, then *Scheduled* with the project's tasks.
/// There is no Thread/Tasks switch: choosing a row shows that thread or that task.
struct PreviewRail: View {
    var store: ProjectStore
    static let width: CGFloat = 288

    var body: some View {
        let model = RailModel.derive(
            listing: store.threads.listing, tasks: store.tasks.snapshot(for: store.project), composing: store.newThread,
            limit: store.railLimit, shown: shownThreadID)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxs) {
                header("THREADS") {
                    Button { store.beginNewGoal() } label: { Image(systemName: "plus") }
                        .iconButton(size: .small).disabled(store.project == nil)
                    .accessibilityLabel("New goal").help("New goal…")
                }
                if let composing = model.composing { RailRowView(row: composing, selected: true) {} }
                if model.threads.isEmpty && model.composing == nil {
                    Text(store.project == nil ? "Choose a project to see its threads." : "No threads yet.")
                        .role(.caption).padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                } else if !model.threads.isEmpty {
                    ThreadListView(store: store, rows: model.threads, hidden: model.hidden, older: model.older)
                }
                header(model.scheduledHeader) {
                    Button { store.beginNewTask() } label: { Image(systemName: "plus") }
                        .iconButton(size: .small).disabled(store.project == nil)
                        .accessibilityLabel("New task").help("New task…")
                }
                .padding(.top, Space.m)
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
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.m)
        }
        // The tasks are read while the rail is on screen, as the Tasks screen did while it was: the section is never stale for long.
        .task(id: store.project?.root.path) {
            var first = true
            while !Task.isCancelled {
                await store.tasks.refreshIfDue(store.project, visible: true, force: first)
                first = false
                try? await Task.sleep(for: .seconds(5))
            }
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

    private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack {
            Text(title).textStyle(.captionStrong, .secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, Space.s).padding(.bottom, Space.xs)
    }
}
