import SwiftUI

/// The small caps label over a block ("NEXT", "GOAL", "DENIED CALLS"): one size, weight and spacing everywhere.
struct SectionLabel: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}
