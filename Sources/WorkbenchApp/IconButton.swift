import SwiftUI

/// A button that is only a symbol. It always has a name for assistive technology and a tooltip, which an icon alone cannot give.
/// `close` and `badge` are the bare ones (a close on a card, a remove beside a row); `raised` is the square from `ButtonStyles.swift` (a
/// composer's Send, a "+" beside a title). A view never writes `Image(systemName: "xmark")` or `.iconButton(` (`scripts/check-banned-apis.sh`).
struct IconButton: View {
    enum Look {
        case bare
        case raised(ButtonSize)
    }

    var symbol: String
    var label: String
    var help: String?
    var look: Look
    var action: () -> Void

    var body: some View {
        switch look {
        case .bare:
            Button(action: action) { Image(systemName: symbol).textStyle(.captionStrong) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(label).help(help ?? label)
        case .raised(let size):
            Button(action: action) { Image(systemName: symbol) }
                .iconButton(size: size).accessibilityLabel(label).help(help ?? label)
        }
    }

    /// A cross that closes what it is on, or removes the row it sits beside.
    static func close(_ label: String, help: String? = nil, action: @escaping () -> Void) -> IconButton {
        IconButton(symbol: "xmark", label: label, help: help, look: .bare, action: action)
    }

    /// A filled cross on a thumbnail, to take it away.
    static func badge(_ label: String, help: String? = nil, action: @escaping () -> Void) -> IconButton {
        IconButton(symbol: "xmark.circle.fill", label: label, help: help, look: .bare, action: action)
    }

    /// A raised square holding a symbol.
    static func raised(
        _ symbol: String, _ label: String, help: String? = nil, size: ButtonSize = .compact, action: @escaping () -> Void
    ) -> IconButton {
        IconButton(symbol: symbol, label: label, help: help, look: .raised(size), action: action)
    }
}
