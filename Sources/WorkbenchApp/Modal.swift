import SwiftUI

/// How wide a modal is: a named step, never a number at the call site. A width the steps lack is a new case here, decided once.
enum ModalSize {
    /// A short list and a search field (the project picker).
    case small
    /// A form of a few rows (the Agents card).
    case medium

    var width: CGFloat {
        switch self {
        case .small: 420
        case .medium: 560
        }
    }
}

/// Where a modal sits over the window.
enum ModalPlacement {
    /// In the middle.
    case centered
    /// Under the toolbar at the left edge, where the pill that opened it is.
    case topLeading

    var alignment: Alignment { self == .centered ? .center : .topLeading }
    var transition: AnyTransition { self == .centered ? .opacity : .opacity.combined(with: .offset(y: -6)) }
}

/// What the close control is called to assistive technology, and so to `scripts/verify-app.sh`.
enum ModalText {
    static func closeLabel(_ title: String) -> String { "Close the \(title.lowercased()) panel" }
}

/// The card, its title and its one way out, which is Esc and the close button.
private struct ModalCard<Content: View>: View {
    var title: String
    var size: ModalSize
    var close: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                SectionLabel(title.uppercased())
                Spacer()
                Button(action: close) { Image(systemName: "xmark").textStyle(.captionStrong) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
                    .accessibilityLabel(ModalText.closeLabel(title))
            }
            content()
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.l)
        .frame(width: size.width)
        .card(.popover)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        // Both ways, because each misses a case: a focused text field takes Esc before a button's shortcut sees it (`onExitCommand` gets
        // it), and with nothing focused `onExitCommand` hears nothing (the shortcut does).
        .onExitCommand(perform: close)
    }
}

private struct ModalPresentation<Presented: View>: ViewModifier {
    var title: String
    @Binding var isPresented: Bool
    var size: ModalSize
    var placement: ModalPlacement
    var closesOnOutsideClick: Bool
    @ViewBuilder var presented: () -> Presented

    func body(content: Content) -> some View {
        content
            // Modal: what is behind it takes no click and no Tab until it closes.
            .disabled(isPresented)
            .overlay {
                ZStack(alignment: placement.alignment) {
                    if isPresented {
                        Color.black.opacity(0.12).contentShape(Rectangle())
                            .onTapGesture { if closesOnOutsideClick { isPresented = false } }.transition(.opacity)
                        ModalCard(title: title, size: size, close: { isPresented = false }, content: presented)
                            .padding(.top, placement == .centered ? 0 : Space.giant)
                            .padding(.leading, placement == .centered ? 0 : Space.m)
                            .transition(placement.transition)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isPresented)
                .accessibilityAddTraits(isPresented ? .isModal : [])
            }
    }
}

extension View {
    /// A card over the window with a veil behind it, a title, and Esc and a close button as the way out. Every modal in the app is this:
    /// a different look or behaviour is a new `size`, `placement` or prop here, not a `.sheet` or an overlay written in a view
    /// (`scripts/check-banned-apis.sh` fails one). Pass `closesOnOutsideClick: false` where a stray click would lose typed text.
    func modal<Presented: View>(
        _ title: String, isPresented: Binding<Bool>, size: ModalSize, placement: ModalPlacement = .centered,
        closesOnOutsideClick: Bool = true, @ViewBuilder content: @escaping () -> Presented
    ) -> some View {
        modifier(
            ModalPresentation(
                title: title, isPresented: isPresented, size: size, placement: placement,
                closesOnOutsideClick: closesOnOutsideClick, presented: content))
    }
}
