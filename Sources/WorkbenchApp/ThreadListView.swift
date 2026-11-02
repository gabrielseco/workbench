import SwiftUI

/// The project's threads in the rail (P22 slice 5): one row each, newest first. A click shows that thread; it starts and stops nothing.
struct ThreadListView: View {
    var store: ProjectStore

    /// The screen is what is observed, so the highlight follows it; `currentThread` is not.
    private var shownThread: String? {
        if case .thread(let snapshot) = store.screen { return snapshot.id }
        return nil
    }

    /// The row above or below the one shown, for the arrow keys; nil at either end or when none is shown.
    static func neighbour(of shown: String?, in ids: [String], up: Bool) -> String? {
        guard let at = shown.flatMap({ ids.firstIndex(of: $0) }) else { return nil }
        let next = up ? at - 1 : at + 1
        return ids.indices.contains(next) ? ids[next] : nil
    }

    var body: some View {
        let listing = store.threads.listing
        let shown = shownThread
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(listing.rows) { row in
                    ThreadRowView(row: row, selected: row.id == shown) {
                        Task { await store.select(thread: row.id) }
                    }
                }
                if listing.older > 0 {
                    Text(listing.older == 1 ? "1 older thread" : "\(listing.older) older threads")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 4)
                        .help("The log and the workbench command still reach them")
                }
            }
        }
        .accessibilityLabel("Threads")
        .focusable()
        .onMoveCommand { direction in
            guard direction == .up || direction == .down,
                let next = ThreadListView.neighbour(of: shown, in: listing.rows.map(\.id), up: direction == .up)
            else { return }
            Task { await store.select(thread: next) }
        }
    }
}

struct ThreadRowView: View {
    var row: ThreadRow
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: row.mark.symbol).foregroundStyle(row.mark.tint).frame(width: 14).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(2)
                    Text(row.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.blue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.title): \(row.line)")
        .accessibilityLabel("\(row.title), \(row.mark.word), \(row.line)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension ThreadMark {
    /// A symbol and a word beside the tint, so colour is never the only signal.
    var symbol: String {
        switch self {
        case .working: "circle.inset.filled"
        case .needsYou: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .broken: "xmark.octagon.fill"
        }
    }

    var word: String {
        switch self {
        case .working: "working"
        case .needsYou: "needs you"
        case .done: "done"
        case .idle: "waiting"
        case .broken: "broken"
        }
    }

    var tint: Color {
        switch self {
        case .working: Theme.blue
        case .needsYou: Theme.amber
        case .done: Theme.green
        case .idle: Theme.grey
        case .broken: Theme.red
        }
    }
}
