import SwiftUI

/// What a piece of text is for. Each role is one font and one colour, so "a caption" or "an error" reads the same on every screen.
enum TextRole {
    /// A small line under or beside something: secondary caption.
    case caption
    /// A sentence of explanation: secondary callout.
    case detail
    /// Something went wrong: callout in the broken colour.
    case error
    /// Something needs a decision: callout in the amber.
    case warning
    /// A path, a command or an id, small: monospaced secondary caption.
    case mono
    /// A path or a command as the line's content: monospaced secondary callout.
    case monoDetail
}

extension TextRole {
    var font: Font {
        switch self {
        case .caption: .caption
        case .detail, .error, .warning: .callout
        case .mono: .system(.caption, design: .monospaced)
        case .monoDetail: .system(.callout, design: .monospaced)
        }
    }

    var color: Color {
        switch self {
        case .error: Theme.red
        case .warning: Theme.amber
        default: Color.secondary
        }
    }
}

extension View {
    /// The same roles for a view that is not a `Text` (a `Label`, a row): its font and colour reach the text inside it.
    func textRole(_ role: TextRole) -> some View { font(role.font).foregroundStyle(role.color) }
}

extension Text {
    /// The text in its role's font and colour. A new look is a new `TextRole`, not a font and a colour written beside the text.
    func role(_ role: TextRole) -> Text {
        font(role.font).foregroundStyle(role.color)
    }
}
