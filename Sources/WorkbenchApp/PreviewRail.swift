import SwiftUI
import WorkbenchCore

/// The rail with the chat feed preview on (design parity 4): one list, *Threads* with a `+`, then *Scheduled* with the project's tasks.
/// There is no Thread/Tasks switch: choosing a row shows that thread or that task.
struct PreviewRail: View {
    var store: ProjectStore

    static let width: CGFloat = 288

    var body: some View {
        let model = RailModel.derive(
            listing: store.threads.listing, tasks: store.tasks.snapshot(for: store.project), composing: store.newThread)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header("THREADS") {
                    Button { store.beginNewGoal() } label: {
                        Image(systemName: "plus").font(.callout.weight(.semibold)).frame(width: 24, height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                    }
                    .buttonStyle(.plain).disabled(store.project == nil || store.namingGoal)
                    .accessibilityLabel("New goal").help("New goal…")
                }
                if let composing = model.composing { RailRowView(row: composing, selected: true) {} }
                if model.threads.isEmpty && model.composing == nil {
                    Text(store.project == nil ? "Choose a project to see its threads." : "No threads yet.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                } else if !model.threads.isEmpty {
                    ThreadListView(store: store)
                }
                header(model.scheduledHeader).padding(.top, 10)
                if let note = model.scheduledNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                    if model.tasksRead {
                        // No row to choose: this is the way to the Tasks page, which says where tasks are made and what the timer is doing.
                        Button("Open the Tasks page") { store.showTasks() }
                            .buttonStyle(.link).font(.caption).padding(.horizontal, 8)
                            .accessibilityLabel("Open the Tasks page").help("Where tasks are made, and what the timer is doing")
                    }
                }
                let shownTask = shownTaskName
                ForEach(model.tasks) { row in
                    RailRowView(row: row, selected: row.key == shownTask) { store.selectTask(row.key) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
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

    /// The task on screen, when a task is: the highlighted row. The first one the Tasks screen would pick when none was chosen.
    private var shownTaskName: String? {
        guard store.mode == .tasks, !store.newThread, let snapshot = store.tasks.snapshot(for: store.project) else { return nil }
        return store.tasks.selected(in: snapshot)?.id
    }

    private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
    }
}
