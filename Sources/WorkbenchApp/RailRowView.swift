import SwiftUI

/// A row of the rail as the artboards draw it: the mark at the left, the title on one line, and the state line under it, coloured by the
/// mark. The selected row sits on a raised surface.
struct RailRowView: View {
    var row: RailRow
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Space.m) {
                RailMark(mark: row.mark).symbolColumn(square: true)
                // One line: the title and, beside it, the mark. What the row says in words (its state) is the hover text and the
                // accessibility label, and opening the row says the rest.
                Text(row.title).textStyle(.calloutStrong).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Space.none)
            }
            .padding(.horizontal, Space.s).padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.box))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.help)
        .accessibilityLabel(row.accessibility)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The artboards' marks: working a spinner, needs you a dot with a halo, done a check, idle a hollow ring, broken a cross.
struct RailMark: View {
    var mark: ThreadMark

    var body: some View {
        switch mark {
        case .working: Spinner(.rail)
        case .needsYou:
            StatusDot(Theme.amber, filled: true, halo: true)
        case .done: Image(systemName: "checkmark").textStyle(.captionBold, .green)
        case .idle: StatusDot()
        case .broken: StatusMark(.failed)
        }
    }
}

extension ThreadMark {
    /// A symbol and a word beside the tint, so colour is never the only signal.
    var symbol: String {
        switch self {
        case .working: "circle.inset.filled"
        case .needsYou: Outcome.warning.symbol
        case .done: Outcome.passed.symbol
        case .idle: "circle"
        case .broken: Outcome.failed.symbol
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
