import AppKit
import SwiftUI

/// The app's one multi-line text box. `TextEditor` has no placeholder, so the placeholder is drawn over it, and where it sits has to match
/// where the text view starts its text: written down once, here, and measured (`scripts/check-text-alignment.py` compares the placeholder's
/// rows with typed text's). A hand-placed overlay was 6 pt off the line you type on and the caret looked wrong beside it, three times. Every
/// text box in the app is this view, and `scripts/check-banned-apis.sh` fails a `TextEditor(` anywhere else.
struct PlaceholderTextEditor: View {
    @Binding var text: String
    var placeholder = ""
    var style: TextStyle = .body
    var lineSpacing: CGFloat = 0
    /// The box is one or two lines and grows with its text: its scroll bar would sit in the panel as a stray pill, so it is taken off.
    /// A tall box that scrolls keeps its own.
    var hidesScroller = false
    var scrollDisabled = false
    /// When the placeholder shows: by default while the text is empty.
    var showsPlaceholder: Bool?
    var accessibilityLabel: String?
    var focus: FocusState<Bool>.Binding?
    /// Fits the box to its text, wrapped lines included, between the size's fewest and most lines (then it scrolls). nil leaves the height to the caller.
    var growth: Growth?
    /// Return, and the keys that go with it: `.handled` to take it, `.ignored` to let the text view have it (a new line).
    var onReturn: ((KeyPress) -> KeyPress.Result)?

    /// How tall a box that fits its text may be, decided once: a chat composer is one line when empty, a note a few, a form field roomy,
    /// and a document's text in place (a goal's request) one line when short and a page before it scrolls.
    enum Growth {
        case compact, regular, roomy, document

        var lines: ClosedRange<Int> {
            switch self {
            case .compact: 1...6
            case .regular: 3...8
            case .roomy: 4...10
            case .document: 1...16
            }
        }
    }

    @State private var contentHeight: CGFloat = 0
    @State private var lineHeight: CGFloat = 0

    /// Where the text view starts its text, relative to the box: the placeholder is drawn here. The leading 5 is the text container's line
    /// fragment padding; the text starts at the top edge.
    static let placeholderInset = (leading: CGFloat(5), top: CGFloat(0))

    var body: some View {
        optional(
            optional(
                optional(
                    TextEditor(text: $text).textStyle(style).lineSpacing(lineSpacing).scrollContentBackground(.hidden)
                        .scrollDisabled(scrollDisabled), focus
                ) { $0.focused($1) }, onReturn
            ) { view, handler in view.onKeyPress(.return, phases: .down, action: handler) }, accessibilityLabel
        ) { $0.accessibilityLabel($1) }
        .frame(height: fittedHeight)
        .background(alignment: .topLeading) { if growth != nil { measuring } }
        .background { if hidesScroller { TextScrollerHider() } }
        .overlay(alignment: .topLeading) {
            if showsPlaceholder ?? text.isEmpty, !placeholder.isEmpty {
                Text(placeholder).textStyle(style).lineSpacing(lineSpacing).foregroundStyle(.tertiary)
                    .padding(.leading, Self.placeholderInset.leading).padding(.top, Self.placeholderInset.top)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The height for the text's rows, clamped to `lines`; nil until measured, so the first frame is not collapsed.
    private var fittedHeight: CGFloat? {
        guard let lines = growth?.lines, lineHeight > 0 else { return nil }
        let step = lineHeight + lineSpacing
        let wrapped = ((contentHeight + lineSpacing) / step).rounded()
        let rows = min(CGFloat(lines.upperBound), max(CGFloat(lines.lowerBound), wrapped))
        return lineHeight + (rows - 1) * step
    }

    /// Two invisible copies of the text in the same face and width: the whole text, for how many rows it wraps into, and one line, for a row.
    private var measuring: some View {
        ZStack(alignment: .topLeading) {
            // A trailing newline is a row to type on, and `Text` drops it, so it gets a space to hold the row.
            Text(text.hasSuffix("\n") ? text + " " : text).textStyle(style).lineSpacing(lineSpacing)
                .padding(.horizontal, Self.placeholderInset.leading).fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { contentHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { contentHeight = proxy.size.height }
                })
            Text("Ag").textStyle(style).fixedSize()
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { lineHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { lineHeight = proxy.size.height }
                })
        }
        .hidden().allowsHitTesting(false).accessibilityHidden(true)
    }

    /// A modifier applied only when its value is there: nothing is attached for a box that has no focus binding, no key handler or no label.
    @ViewBuilder private func optional<V: View, T>(_ view: V, _ value: T?, apply: (V, T) -> some View) -> some View {
        if let value { apply(view, value) } else { view }
    }
}
