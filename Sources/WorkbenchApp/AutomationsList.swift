import SwiftUI

/// The Automations view's list, at the left of the task's page (P26 slice 5): `SCHEDULED · N` and a row for each task, with its mark, its name
/// and under it its schedule and how the last run went. Under them the archived tasks, folded until `Archived · N` is pressed. A click shows
/// that task and so do the arrow keys; nothing is started by looking.
struct AutomationsList: View {
    var store: ProjectStore
    var snapshot: TasksSnapshot
    static let width: CGFloat = 360
    @FocusState private var focused: Bool

    /// The task above or below the one shown, for the arrow keys; nil at either end or when none is shown.
    static func neighbour(of shown: String?, in names: [String], up: Bool) -> String? {
        InboxModel.neighbour(of: shown, in: names, up: up)
    }

    /// The rows the arrows walk: the active tasks, then the archived ones while their fold is open.
    static func walked(_ snapshot: TasksSnapshot, archivedOpen: Bool) -> [String] {
        snapshot.entries.map(\.id) + (archivedOpen ? snapshot.archived.map(\.id) : [])
    }

    var body: some View {
        let selected = store.tasks.selected(in: snapshot)?.id
        // An archived task on the page keeps its fold open, so the row it was opened from stays in sight.
        let archivedOpen = store.tasks.archivedShown || snapshot.archived.contains { $0.id == selected }
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
                if !snapshot.archived.isEmpty {
                    DisclosureToggle(label: "Archived · \(snapshot.archived.count)", isOpen: archivedOpen) {
                        store.tasks.archivedShown = !archivedOpen
                    }
                    .padding(.horizontal, Space.s).padding(.top, Space.m).padding(.bottom, Space.xs)
                    if archivedOpen {
                        ForEach(snapshot.archived) { entry in
                            let row = InboxRow(automation: RailRow.task(entry))
                            InboxRowView(row: row, selected: entry.id == selected, automationTag: false) {
                                store.selectTask(entry.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.m)
            // One focus stop for the list, so the arrows walk the tasks.
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onChange(of: focused) { store.listFocused = focused }
            .onDisappear { store.listFocused = false }
            .listHasKeys(focused)
            .onMoveCommand { direction in
                guard direction == .up || direction == .down,
                    let next = Self.neighbour(
                        of: selected, in: Self.walked(snapshot, archivedOpen: archivedOpen), up: direction == .up)
                else { return }
                store.selectTask(next)
            }
        }
        .frame(width: Self.width).background(Theme.rail)
        .accessibilityLabel("Scheduled automations")
    }
}
