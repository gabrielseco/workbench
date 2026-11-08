import SwiftUI

/// The rail's list when the top tile is chosen (P26 slice 4b): every project's threads in the three sections, each row with its project's
/// initials. A click opens that project and shows the thread (or the automation's task).
struct AllInboxView: View {
    var store: ProjectStore
    var model: AllInboxModel

    private var shown: (project: String?, thread: String?) {
        if store.mode == .thread, !store.newThread, case .thread(let snapshot) = store.screen {
            return (store.project?.root.path, snapshot.id)
        }
        return (nil, nil)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.xxs) {
            section(.needsYou, model.needsYou, tone: .amber)
            section(.waiting, model.waiting, tone: .secondary)
            if model.finishedCount > 0 {
                InboxSectionHeader(title: InboxSection.done.title, count: model.finishedCount, tone: .secondary)
                ForEach(model.done) { rowView($0) }
                doneToggle
            }
        }
        .accessibilityLabel("Inbox of all projects")
    }

    @ViewBuilder private func section(_ section: InboxSection, _ rows: [AllInboxRow], tone: TextTone) -> some View {
        if !rows.isEmpty {
            InboxSectionHeader(title: section.title, count: rows.count, tone: tone)
            ForEach(rows) { rowView($0) }
        }
    }

    private func rowView(_ entry: AllInboxRow) -> some View {
        let here = shown
        let selected = entry.row.kind == .thread && entry.project == here.project && entry.row.key == here.thread
        return InboxRowView(row: entry.row, selected: selected, project: entry.initials, accessibility: entry.accessibility) {
            Task { await store.open(entry) }
        }
        .help("\(entry.name): \(entry.row.title), \(entry.row.line)")
    }

    /// `Show 9 finished threads` while Done is closed, `Hide finished threads` once it is open.
    @ViewBuilder private var doneToggle: some View {
        if model.doneHidden > 0 {
            let words = model.doneHidden == 1 ? "1 finished thread" : "\(model.doneHidden) finished threads"
            Button("Show \(words)") { store.toggleAllDoneOpen() }
                .buttonStyle(.link).textStyle(.caption).padding(.horizontal, Space.s).padding(.top, Space.xs)
                .accessibilityLabel("Show \(words)").help("The threads that are over, in every project")
        } else if store.allInboxDoneOpen {
            Button("Hide finished threads") { store.toggleAllDoneOpen() }
                .buttonStyle(.link).textStyle(.caption).padding(.horizontal, Space.s).padding(.top, Space.xs)
                .accessibilityLabel("Hide finished threads")
        }
    }
}
