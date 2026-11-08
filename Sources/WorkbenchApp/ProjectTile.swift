import SwiftUI

/// One project of the rail: two letters in a rounded square, a bar at the edge while it is the open one, and its badge at the corner. A
/// project that cannot be opened is dimmed and says why in its tooltip. It is a button; its menu is the caller's.
struct ProjectTile: View {
    var project: RailProject
    var selected: Bool
    var badge: RailBadge
    var action: () -> Void

    static let side: CGFloat = 44
    private static let bar = CGSize(width: 4, height: 28)

    private var available: Bool { project.unavailable == nil }

    var body: some View {
        Button(action: action) {
            Text(project.initials).textStyle(.bodyStrong).foregroundStyle(available ? .primary : .secondary)
                .frame(width: Self.side, height: Self.side)
                .background(selected ? Theme.blue.opacity(0.18) : Theme.panel, in: shape)
                .overlay(shape.strokeBorder(selected ? Theme.blue : Theme.line))
                .opacity(available ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let kind = CountBadge.Kind(badge) { CountBadge(kind: kind).offset(x: Space.s, y: -Space.s) }
        }
        .overlay(alignment: .leading) {
            if selected {
                UnevenRoundedRectangle(bottomTrailingRadius: Radius.thumbnail, topTrailingRadius: Radius.thumbnail)
                    .fill(Theme.blue).frame(width: Self.bar.width, height: Self.bar.height).offset(x: -Space.xxxl / 2 + Space.xxs)
            }
        }
        .accessibilityLabel(badge.label(for: project.name) + (project.unavailable.map { ", unavailable: \($0)" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(project.unavailable ?? project.name + " · " + (project.path as NSString).abbreviatingWithTildeInPath)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.card) }
}
