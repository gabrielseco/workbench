import SwiftUI

/// One choice of a `SegmentedSwitch`: its words, an optional count, and the tone the count takes (amber for what needs you).
struct SwitchSegment: Identifiable {
    var id: String
    var title: String
    var count: Int?
    var tone: TextTone = .secondary
    /// What VoiceOver says: the title and what the count counts.
    var accessibility: String
}

/// A row of choices in a capsule, one selected, each with its count beside the words (the top bar's Inbox / Automations). A choice has
/// a word as well as a count and a tone, so colour is never the only signal.
struct SegmentedSwitch: View {
    var segments: [SwitchSegment]
    var selection: String
    var enabled = true
    var action: (String) -> Void

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(segments) { segment in
                let selected = segment.id == selection
                Button { action(segment.id) } label: {
                    HStack(spacing: Space.s) {
                        Text(segment.title).textStyle(.calloutStrong, selected ? .primary : .secondary)
                        if let count = segment.count, count > 0 { Text("\(count)").textStyle(.captionStrong, segment.tone) }
                    }
                    .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
                    .background(selected ? Theme.raised : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.accessibility)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Space.xxs)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .disabled(!enabled)
    }
}
