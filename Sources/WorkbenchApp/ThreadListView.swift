import SwiftUI

/// The project's threads in the rail (P22 slice 5): one row each, newest first. A click shows that thread; it starts and stops nothing.
struct ThreadListView: View {
    var store: ProjectStore
    /// The rows of THREADS (the listing without the finished threads a task started) and how many older ones the listing left out.
    var rows: [RailRow]
    var older: Int

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
        let shown = shownThread
        let selectedHere = store.mode == .thread && !store.newThread
        LazyVStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(rows) { row in
                RailRowView(row: row, selected: selectedHere && row.key == shown) {
                    Task { await store.select(thread: row.key) }
                }
            }
            if older > 0 {
                Text(older == 1 ? "1 older thread" : "\(older) older threads")
                    .role(.caption).padding(.horizontal, Space.s).padding(.top, Space.xs)
                    .help("The log and the workbench command still reach them")
            }
        }
        .accessibilityLabel("Threads")
        .focusable()
        .onMoveCommand { direction in
            guard direction == .up || direction == .down,
                let next = ThreadListView.neighbour(of: shown, in: rows.map(\.key), up: direction == .up)
            else { return }
            Task { await store.select(thread: next) }
        }
    }
}

/// A row of the rail as the artboards draw it: the mark at the left, the title on one line, and the state line under it, coloured by the
/// mark. The selected row sits on a raised surface.
struct RailRowView: View {
    var row: RailRow
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Space.m) {
                RailMark(mark: row.mark).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(row.title).textStyle(.calloutStrong).lineLimit(1).truncationMode(.middle)
                    Text(row.line).textStyle(.caption).lineLimit(1)
                        .foregroundStyle(row.mark.lineTint == .quiet ? Color.secondary : row.mark.tint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s).padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.box))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.title): \(row.line)")
        .accessibilityLabel("\(row.title), \(row.mark.word), \(row.line)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The artboards' marks: working a spinner, needs you a dot with a halo, done a check, idle a hollow ring, broken a cross.
struct RailMark: View {
    var mark: ThreadMark

    var body: some View {
        switch mark {
        case .working: ProgressView().controlSize(.small).scaleEffect(0.7).tint(Theme.blue)
        case .needsYou:
            Circle().fill(Theme.amber).frame(width: 9, height: 9)
                .background(Circle().fill(Theme.amber.opacity(0.24)).frame(width: 15, height: 15))
        case .done: Image(systemName: "checkmark").textStyle(.captionBold, .green)
        case .idle: Circle().strokeBorder(Theme.grey, lineWidth: 1.5).frame(width: 9, height: 9)
        case .broken: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
        }
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
