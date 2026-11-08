import SwiftUI

/// One project of the rail: its generated picture (`ProjectGlyph`) in a rounded square, a bar at the edge while it is the open one, and its badge at the corner. A
/// project that cannot be opened is dimmed and says why in its tooltip. It is a button; its menu is the caller's.
struct ProjectTile: View {
    var project: RailProject
    var selected: Bool
    var badge: RailBadge
    /// An SF Symbol in place of the initials, for a tile that is not a project (the inbox of all of them), and the tooltip it has then.
    var symbol: String?
    var tooltip: String?
    var action: () -> Void

    static let side: CGFloat = 44
    private static let bar = CGSize(width: 4, height: 28)

    private var available: Bool { project.unavailable == nil }

    var body: some View {
        VStack(spacing: Space.xs) {
            tile
            // The name under a project's picture, always: a tooltip waits and a person scanning the rail does not hover.
            if symbol == nil {
                Text(project.name).textStyle(.caption, selected ? .primary : .secondary).lineLimit(1).truncationMode(.middle)
                    .frame(width: Self.side + Space.l).accessibilityHidden(true)
            }
        }
    }

    private var tile: some View {
        Button(action: action) {
            face
                .frame(width: Self.side, height: Self.side)
                .background(selected ? Theme.blue.opacity(0.18) : Theme.panel, in: shape)
                .overlay(shape.strokeBorder(selected ? Theme.blue : Theme.line))
                .selectedFocusRing(selected, radius: Radius.card)
                .opacity(available ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let kind = CountBadge.Kind(badge) { CountBadge(kind: kind).offset(x: Space.s, y: -Space.s) }
        }
        // A folder that is gone is said by a mark as well as by dimming: colour is never the only signal.
        .overlay(alignment: .bottomTrailing) {
            if !available {
                StatusMark(.failed).textStyle(.captionBold).background(Theme.rail, in: Circle()).offset(x: Space.xs, y: Space.xs)
            }
        }
        .overlay(alignment: .leading) {
            if selected {
                UnevenRoundedRectangle(bottomTrailingRadius: Radius.thumbnail, topTrailingRadius: Radius.thumbnail)
                    .fill(Theme.blue).frame(width: Self.bar.width, height: Self.bar.height).offset(x: -Space.xxxl / 2 + Space.xxs)
            }
        }
        .accessibilityLabel(badge.label(for: project.name) + (project.unavailable.map { ", unavailable: \($0)" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(tooltip ?? project.unavailable ?? project.name + " · " + (project.path as NSString).abbreviatingWithTildeInPath)
    }

    @ViewBuilder private var face: some View {
        if let symbol {
            Image(systemName: symbol).textStyle(.heading, selected ? .primary : .secondary)
        } else {
            ProjectGlyph(path: project.path).foregroundStyle(selected ? Theme.blue : Theme.fg2)
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.card) }
}
