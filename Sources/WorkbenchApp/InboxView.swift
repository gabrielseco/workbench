import SwiftUI

/// The project's threads as an inbox (P26): Needs you, Waiting, and Done (collapsed, with how many it holds). A click shows that thread; it
/// starts and stops nothing.
struct InboxView: View {
    var store: ProjectStore
    var model: InboxModel

    /// The screen is what is observed, so the highlight follows it; `currentThread` is not.
    private var shownThread: String? {
        if case .thread(let snapshot) = store.screen { return snapshot.id }
        return nil
    }

    var body: some View {
        let shown = shownThread
        let selectedHere = store.mode == .thread && !store.newThread
        LazyVStack(alignment: .leading, spacing: Space.xxs) {
            if let composing = model.composing { RailRowView(row: composing, selected: true) {} }
            section(.needsYou, model.needsYou, tone: .amber, shown: shown, selectedHere: selectedHere)
            section(.waiting, model.waiting, tone: .blue, shown: shown, selectedHere: selectedHere)
            if model.finishedCount > 0 {
                InboxSectionHeader(title: InboxSection.done.title, count: model.finishedCount, tone: .secondary)
                ForEach(model.done) { row in rowView(row, shown: shown, selectedHere: selectedHere) }
                doneToggle
            }
            if model.older > 0 {
                Text(model.older == 1 ? "1 older thread" : "\(model.older) older threads")
                    .role(.caption).padding(.horizontal, Space.s).padding(.top, Space.xs)
                    .help(InboxModel.olderHelp(model.older))
            }
        }
        .accessibilityLabel("Inbox")
    }

    @ViewBuilder private func section(
        _ section: InboxSection, _ rows: [InboxRow], tone: TextTone, shown: String?, selectedHere: Bool
    ) -> some View {
        if !rows.isEmpty {
            InboxSectionHeader(title: section.title, count: rows.count, tone: tone)
            ForEach(rows) { row in rowView(row, shown: shown, selectedHere: selectedHere) }
        }
    }

    private func rowView(_ row: InboxRow, shown: String?, selectedHere: Bool) -> some View {
        InboxRowView(row: row, selected: selectedHere && row.kind == .thread && row.key == shown) {
            if row.isAutomation { store.selectTask(row.key) } else { Task { await store.select(thread: row.key) } }
        }
    }

    /// `Show 9 finished threads` while Done is closed, `Hide finished threads` once it is open.
    @ViewBuilder private var doneToggle: some View {
        if model.doneHidden > 0 {
            let words = model.doneHidden == 1 ? "1 finished thread" : "\(model.doneHidden) finished threads"
            let help = "The threads that are over"
            FoldToggle(title: "Show \(words)", expanded: false, help: help) { store.toggleDoneOpen() }
        } else if store.doneOpen {
            FoldToggle(title: "Hide finished threads", expanded: true, help: "Close them") { store.toggleDoneOpen() }
        }
    }
}
