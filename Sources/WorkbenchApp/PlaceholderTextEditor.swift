import AppKit
import SwiftUI

/// The app's one multi-line text box. `TextEditor` has no placeholder, so the placeholder is drawn over it, and where it sits has to match
/// where the text view starts its text: written down once, here, and measured (`scripts/check-text-alignment.py` compares the placeholder's
/// rows with typed text's). A hand-placed overlay was 6 pt off the line you type on and the caret looked wrong beside it, three times. Every
/// text box in the app is this view, and `scripts/check-banned-apis.sh` fails a `TextEditor(` anywhere else.
struct PlaceholderTextEditor: View {
    @Binding var text: String
    var placeholder = ""
    var font: Font = .body
    var lineSpacing: CGFloat = 0
    /// The box is one or two lines and grows with its text: its scroll bar would sit in the panel as a stray pill, so it is taken off.
    /// A tall box that scrolls keeps its own.
    var hidesScroller = false
    var scrollDisabled = false
    /// When the placeholder shows: by default while the text is empty.
    var showsPlaceholder: Bool?
    var accessibilityLabel: String?
    var focus: FocusState<Bool>.Binding?
    /// Return, and the keys that go with it: `.handled` to take it, `.ignored` to let the text view have it (a new line).
    var onReturn: ((KeyPress) -> KeyPress.Result)?

    /// Where the text view starts its text, relative to the box: the placeholder is drawn here. The leading 5 is the text container's line
    /// fragment padding; the text starts at the top edge.
    static let placeholderInset = (leading: CGFloat(5), top: CGFloat(0))

    var body: some View {
        optional(
            optional(
                optional(
                    TextEditor(text: $text).font(font).lineSpacing(lineSpacing).scrollContentBackground(.hidden)
                        .scrollDisabled(scrollDisabled), focus
                ) { $0.focused($1) }, onReturn
            ) { view, handler in view.onKeyPress(.return, phases: .down, action: handler) }, accessibilityLabel
        ) { $0.accessibilityLabel($1) }
        .background { if hidesScroller { TextScrollerHider() } }
        .overlay(alignment: .topLeading) {
            if showsPlaceholder ?? text.isEmpty, !placeholder.isEmpty {
                Text(placeholder).font(font).lineSpacing(lineSpacing).foregroundStyle(.tertiary)
                    .padding(.leading, Self.placeholderInset.leading).padding(.top, Self.placeholderInset.top)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A modifier applied only when its value is there: nothing is attached for a box that has no focus binding, no key handler or no label.
    @ViewBuilder private func optional<V: View, T>(_ view: V, _ value: T?, apply: (V, T) -> some View) -> some View {
        if let value { apply(view, value) } else { view }
    }
}
