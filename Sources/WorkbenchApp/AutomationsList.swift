import SwiftUI

/// The Automations view's list, at the left of the task's page (P26 slice 5): one row per task with its mark and its schedule · last run. A
/// click shows that task; nothing is started by looking.
struct AutomationsList: View {
    var store: ProjectStore
    var snapshot: TasksSnapshot
    static let width: CGFloat = 288

    var body: some View {
        let selected = store.tasks.selected(in: snapshot)?.id
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xxs) {
                HStack {
                    Text("AUTOMATIONS · \(snapshot.entries.count)").textStyle(.captionStrong, .secondary)
                    Spacer()
                }
                .padding(.horizontal, Space.s).padding(.bottom, Space.xs)
                ForEach(snapshot.entries) { entry in
                    RailRowView(row: RailRow.task(entry), selected: entry.id == selected) { store.selectTask(entry.id) }
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.m)
        }
        .frame(width: Self.width).background(Theme.rail)
        .accessibilityLabel("Automations")
    }
}
