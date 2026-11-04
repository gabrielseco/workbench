import SwiftUI

/// A row that starts with a symbol in a fixed column and sits on the first line of its text: the feed's lines, a tool group, a step to come, a
/// message. What follows the symbol is the caller's; the column, the gap and the baseline are the component's.
struct IconRow<Content: View>: View {
    var symbol: String
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            content
        }
    }
}
