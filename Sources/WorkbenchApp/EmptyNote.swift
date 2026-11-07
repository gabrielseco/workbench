import SwiftUI

/// What a list or a screen says when there is nothing in it: one sentence, in the size of what it stands in for. A screen with something to do
/// next is `EmptyState`.
struct EmptyNote: View {
    enum Size {
        /// In a narrow rail.
        case small
        /// In a list inside a card.
        case medium
        /// Over a whole panel.
        case large
    }

    var text: String
    var size: Size

    init(_ text: String, size: Size = .medium) { (self.text, self.size) = (text, size) }

    var body: some View {
        switch size {
        case .small: Text(text).role(.caption).padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        case .medium: Text(text).role(.detail).padding(.vertical, Space.m).padding(.horizontal, Space.xs)
        case .large: Text(text).role(.detail).padding(Space.xl)
        }
    }
}
