import SwiftUI

/// The Automations view's list, at the left of the task's page (P26 slice 5): `SCHEDULED · N` and a row for each task, with its mark, its name
/// and under it its schedule and how the last run went. A click shows that task and so do the arrow keys; nothing is started by looking.
struct AutomationsList: View {
    var store: ProjectStore
    var snapshot: TasksSnapshot
    static let width: CGFloat = 360

    /// The task above or below the one shown, for the arrow keys; nil at either end or when none is shown.
    static func neighbour(of shown: String?, in names: [String], up: Bool) -> String? {
        InboxModel.neighbour(of: shown, in: names, up: up)
    }

    var body: some View {
        let selected = store.tasks.selected(in: snapshot)?.id
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xxs) {
                HStack {
                    Text("SCHEDULED · \(snapshot.entries.count)").textStyle(.captionStrong, .secondary).tracking(0.6)
                    Spacer()
                }
                .padding(.horizontal, Space.s).padding(.bottom, Space.xs)
                .accessibilityAddTraits(.isHeader)
                ForEach(snapshot.entries) { entry in
                    let row = InboxRow(automation: RailRow.task(entry))
                    InboxRowView(row: row, selected: entry.id == selected, automationTag: false) { store.selectTask(entry.id) }
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.m)
            // One focus stop for the list, so the arrows walk the tasks.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard direction == .up || direction == .down,
                    let next = Self.neighbour(of: selected, in: snapshot.entries.map(\.id), up: direction == .up)
                else { return }
                store.selectTask(next)
            }
        }
        .frame(width: Self.width).background(Theme.rail)
        .accessibilityLabel("Scheduled automations")
    }
}
