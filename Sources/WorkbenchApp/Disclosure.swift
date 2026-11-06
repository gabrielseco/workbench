import SwiftUI

/// A chevron and a label that open or close what is under a row. One component, so every row that opens looks and reads the same.
struct DisclosureToggle: View {
    var label: String
    var isOpen: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.xs) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").textStyle(.captionMedium, .secondary)
                Text(label).role(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOpen ? "open" : "closed")
    }
}

/// What a run did, laid out under its row: a label and a value each, the check's output in the monospaced step.
struct RunDetailView: View {
    var facts: RunDetailFacts

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(facts.facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(fact.label).role(.caption).frame(width: DetailLayout.labelWidth, alignment: .leading)
                    Text(fact.value).role(fact.mono ? .mono : .detail).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if fact.label == "check", !facts.checkTail.isEmpty {
                    Text(facts.checkTail.joined(separator: "\n")).role(.mono).textSelection(.enabled)
                        .padding(.leading, DetailLayout.labelWidth + Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let note = facts.note { Text(note).role(.caption) }
        }
    }
}

enum DetailLayout {
    static let labelWidth: CGFloat = 80
}
