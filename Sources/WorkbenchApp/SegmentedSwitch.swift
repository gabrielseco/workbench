import SwiftUI

/// One choice of a `SegmentedSwitch`: its words, an optional count and the colour the count is filled with (amber for what needs you, red
/// for what failed).
struct SwitchSegment: Identifiable {
    var id: String
    var title: String
    var count: Int?
    var fill: Color = Theme.grey
    /// What VoiceOver says: the title and what the count counts.
    var accessibility: String
}

/// A row of choices in a capsule, one selected, each with its count in a filled pill beside the words (the top bar's Inbox / Automations, as
/// the design has it). A choice has a word as well as a count, so colour is never the only signal.
struct SegmentedSwitch: View {
    var segments: [SwitchSegment]
    var selection: String
    var enabled = true
    var action: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(segments) { segment in
                let selected = segment.id == selection
                Button { action(segment.id) } label: {
                    HStack(spacing: Space.s) {
                        Text(segment.title).textStyle(.calloutStrong, selected ? .primary : .secondary)
                        if let count = segment.count, count > 0 { pill(count, segment.fill) }
                    }
                    .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                    .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.box))
                    .focusRing(selected && focused, radius: Radius.box)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.accessibility)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // One focus stop for the switch: Tab lands here and ← → choose, the way the lists' arrows do.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onMoveCommand { direction in
            guard direction == .left || direction == .right,
                let next = Self.neighbour(of: selection, in: segments.map(\.id), left: direction == .left)
            else { return }
            action(next)
        }
        .padding(Space.xxs)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Theme.line))
        .disabled(!enabled)
    }

    /// The segment left or right of the selected one; nil at either end.
    static func neighbour(of selected: String, in ids: [String], left: Bool) -> String? {
        guard let index = ids.firstIndex(of: selected) else { return nil }
        let next = index + (left ? -1 : 1)
        return ids.indices.contains(next) ? ids[next] : nil
    }

    private func pill(_ count: Int, _ fill: Color) -> some View {
        Text(CountBadge.text(count)).textStyle(.captionStrong).foregroundStyle(Theme.invfg)
            .padding(.horizontal, Space.s).padding(.vertical, Space.xxs).background(fill, in: Capsule())
    }
}
