import SwiftUI
import WorkbenchCore

/// The rail (design parity 4): one list, *Threads* with a `+`, then *Scheduled* with the project's tasks.
/// There is no Thread/Tasks switch: choosing a row shows that thread or that task.
struct PreviewRail: View {
    var store: ProjectStore
    /// The tasks whose threads are listed under them. Not kept between launches.
    @State private var expanded: Set<String> = []

    static let width: CGFloat = 288

    var body: some View {
        let model = RailModel.derive(
            listing: store.threads.listing, tasks: store.tasks.snapshot(for: store.project), composing: store.newThread)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header("THREADS") {
                    Button { store.beginNewGoal() } label: { Image(systemName: "plus") }
                        .iconButton(size: .small).disabled(store.project == nil)
                    .accessibilityLabel("New goal").help("New goal…")
                }
                if let composing = model.composing { RailRowView(row: composing, selected: true) {} }
                if model.threads.isEmpty && model.composing == nil {
                    Text(store.project == nil ? "Choose a project to see its threads." : "No threads yet.")
                        .role(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                } else if !model.threads.isEmpty {
                    ThreadListView(store: store, rows: model.threads, older: model.older)
                }
                header(model.scheduledHeader).padding(.top, 10)
                if let note = model.scheduledNote {
                    Text(note).role(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    if model.tasksRead {
                        // No row to choose: this is the way to the Tasks page, which says where tasks are made and what the timer is doing.
                        Button("Open the Tasks page") { store.showTasks() }
                            .buttonStyle(.link).textStyle(.caption).padding(.horizontal, 8)
                            .accessibilityLabel("Open the Tasks page").help("Where tasks are made, and what the timer is doing")
                    }
                }
                let shownTask = shownTaskName
                ForEach(model.tasks) { row in
                    RailRowView(row: row, selected: row.key == shownTask) { store.selectTask(row.key) }
                    taskThreads(model.taskThreads[row.key] ?? [], task: row.key)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
        }
        // The group holding the thread on screen opens when that changes: the thread is chosen, it ends and moves under its task, or the
        // tasks are read after it. After that the group can be closed.
        .onChange(of: model.group(holding: shownThreadID), initial: true) { _, task in
            if let task { expanded.insert(task) }
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

    /// A task's finished threads: one line with their count, which opens them under the task. The one on screen opens it by itself.
    @ViewBuilder private func taskThreads(_ rows: [RailRow], task: String) -> some View {
        if !rows.isEmpty {
            let shown = shownThreadID
            let open = expanded.contains(task)
            let count = rows.count == 1 ? "1 thread" : "\(rows.count) threads"
            Button {
                if expanded.contains(task) { expanded.remove(task) } else { expanded.insert(task) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").textStyle(.captionStrong)
                    Text(count).textStyle(.caption)
                }
                .foregroundStyle(.secondary).padding(.leading, 30).padding(.vertical, 2)
            }
            .buttonStyle(.plain).accessibilityLabel("\(task): \(count), \(open ? "shown" : "hidden")")
            if open {
                ForEach(rows) { row in
                    RailRowView(row: row, selected: store.mode == .thread && !store.newThread && row.key == shown) {
                        Task { await store.select(thread: row.key) }
                    }
                    .padding(.leading, 16)
                }
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
        .padding(.horizontal, 8).padding(.bottom, 4)
    }
}
