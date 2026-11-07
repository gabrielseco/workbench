import SwiftUI

/// A row that starts with a symbol in a fixed column and sits on the first line of its text: the feed's lines, a tool group, a step to come, a
/// message. What follows the symbol is the caller's; the column, the gap and the baseline are the component's.
struct IconRow<Content: View>: View {
    var symbol: String
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol).foregroundStyle(tint).symbolColumn()
            content
        }
    }
}

/// The width of the column a row's symbol sits in, so what follows lines up with the symbols of the rows around it.
enum SymbolColumn {
    case regular
    /// For a row of small marks (a plan's steps).
    case narrow

    var width: CGFloat { self == .regular ? 16 : 14 }
}

extension View {
    /// This symbol or mark in its row's column. `square` gives the column a height too (a mark that is drawn, not a symbol).
    func symbolColumn(_ column: SymbolColumn = .regular, square: Bool = false) -> some View {
        frame(width: column.width, height: square ? column.width : nil)
    }
}
