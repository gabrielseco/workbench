import SwiftUI

/// A row of the inbox as the artboard draws it: the mark at the left, the title and under it the reason in words, coloured by the mark, and
/// what it has cost at the right. An automation carries an `auto` tag. The selected row sits on a raised surface.
struct InboxRowView: View {
    var row: InboxRow
    var selected: Bool
    /// The project's initials, on a row of the inbox of all projects: whose it is.
    var project: String?
    var accessibility: String?
    var action: () -> Void

    init(row: InboxRow, selected: Bool, project: String? = nil, accessibility: String? = nil, action: @escaping () -> Void) {
        (self.row, self.selected, self.project, self.accessibility, self.action) = (row, selected, project, accessibility, action)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.m) {
                RailMark(mark: row.mark).symbolColumn(square: true).padding(.top, Space.xxs)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.s) {
                        Text(row.title).textStyle(.calloutStrong).lineLimit(1).truncationMode(.middle)
                        if let project { Text(project).pill(style: .outlined) }
                        if row.isAutomation { Text("auto").pill(Theme.grey) }
                    }
                    Text(row.line).textStyle(.caption, row.mark.lineTint == .mark ? .state(row.mark.tint) : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: Space.s)
                if let spend = row.spend { Text(spend).role(.monoDetail) }
            }
            .padding(.horizontal, Space.s).padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.box))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.help)
        .accessibilityLabel(accessibility ?? row.accessibility)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A section's caps label with how many it holds, in its own tone: amber for what needs you, grey for the rest.
struct InboxSectionHeader: View {
    var title: String
    var count: Int
    var tone: TextTone

    var body: some View {
        HStack(spacing: Space.s) {
            Text(title).textStyle(.captionStrong, tone).tracking(0.6)
            Text("\(count)").textStyle(.caption, .secondary)
            Spacer()
        }
        .padding(.horizontal, Space.s).padding(.top, Space.s).padding(.bottom, Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
