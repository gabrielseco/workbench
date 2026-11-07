import AppKit
import SwiftUI

/// How wide a modal is: a named step, never a number at the call site. A width the steps lack is a new case here, decided once.
enum ModalSize {
    /// A short list and a search field (the project picker).
    case small
    /// A form of a few rows (the Agents card).
    case medium
    /// A page of text or a list that scrolls (a diff, the review, what Codex found).
    case large
    /// As wide as its content: a picture shown at its own size (the screenshot preview).
    case fitting

    var width: CGFloat? {
        switch self {
        case .small: 420
        case .medium: 560
        case .large: 760
        case .fitting: nil
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

/// The row of buttons at the foot of a modal: the actions at the trailing edge, and what goes with them (a busy line) at the leading one.
struct ModalFooter<Leading: View, Actions: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Space.s) {
            leading()
            Spacer()
            actions()
        }
    }
}

extension ModalFooter where Leading == EmptyView {
    init(@ViewBuilder actions: @escaping () -> Actions) { self.init(leading: { EmptyView() }, actions: actions) }
}

/// The area a modal has to live in: the window's, which a picture sized to the screen overflowed when the window is smaller.
private struct ModalRoomKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 900, height: 600)
}

extension EnvironmentValues {
    var modalRoom: CGSize {
        get { self[ModalRoomKey.self] }
        set { self[ModalRoomKey.self] = newValue }
    }
}

/// What the close control is called to assistive technology, and so to `scripts/verify-app.sh`.
enum ModalText {
    static func closeLabel(_ title: String) -> String {
        // A word that is all capitals (PR) stays as written; the rest is lower case, as the label reads in a sentence.
        let words = title.split(separator: " ").map { $0 == $0.uppercased() ? String($0) : $0.lowercased() }
        return "Close the \(words.joined(separator: " ")) panel"
    }
}

/// Esc for the modals that are up, newest first: only the last one hears it, so a Diff over a Review closes the Diff and the next Esc the
/// Review. A local key monitor takes the key before the responder chain, and swallows it.
@MainActor final class EscapeKey {
    private static var stack: [ObjectIdentifier] = []
    private var monitor: Any?

    func start(_ close: @escaping () -> Void) {
        guard monitor == nil else { return }
        let id = ObjectIdentifier(self)
        Self.stack.append(id)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 is Esc; a modified one (⌘⎋) is not ours.
            let held: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.keyCode == 53, event.modifierFlags.isDisjoint(with: held) else { return event }
            let isTop = MainActor.assumeIsolated { Self.stack.last == id }
            guard isTop else { return event }
            MainActor.assumeIsolated { close() }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Self.stack.removeAll { $0 == ObjectIdentifier(self) }
    }

    isolated deinit { stop() }
}

/// The card, its title and its one way out, which is Esc (see `EscapeKey`) and the close button.
private struct ModalCard<Accessory: View, Content: View>: View {
    var title: String
    var size: ModalSize
    var close: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @State private var key = EscapeKey()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                SectionLabel(title.uppercased())
                Spacer()
                accessory()
                Button(action: close) { Image(systemName: "xmark").textStyle(.captionStrong) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(ModalText.closeLabel(title)).help("Close (Esc)")
            }
            content()
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.l)
        .frame(width: size.width)
        // A card with no set width is as wide as its content: the header's Spacer would otherwise take all the window.
        .fixedSize(horizontal: size.width == nil, vertical: false)
        .card(.popover)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        // Esc closes the topmost modal wherever the keyboard is. It is taken before the responder chain sees it, because the chain closed
        // the wrong thing: a text field behind a card keeps the keyboard though it is disabled, and took Esc for the screen it is on (it
        // closed the New goal screen under a preview and left the card up), and a card with nothing focused heard no Esc at all.
        .onAppear { key.start(close) }
        .onDisappear { key.stop() }
    }
}

private struct ModalPresentation<Accessory: View, Presented: View>: ViewModifier {
    var title: String
    @Binding var isPresented: Bool
    var size: ModalSize
    var placement: ModalPlacement
    var closesOnOutsideClick: Bool
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var presented: () -> Presented

    func body(content: Content) -> some View {
        content
            // Modal: what is behind it takes no click and no Tab until it closes.
            .disabled(isPresented)
            .overlay {
                GeometryReader { window in
                    ZStack(alignment: placement.alignment) {
                        if isPresented {
                            Color.black.opacity(0.12).contentShape(Rectangle())
                                .onTapGesture { if closesOnOutsideClick { isPresented = false } }.transition(.opacity)
                            ModalCard(
                                title: title, size: size, close: { isPresented = false }, accessory: accessory,
                                content: presented)
                                .padding(.top, placement == .centered ? 0 : Space.giant)
                                .padding(.leading, placement == .centered ? 0 : Space.m)
                                .transition(placement.transition)
                        }
                    }
                    .frame(width: window.size.width, height: window.size.height, alignment: placement.alignment)
                    .environment(\.modalRoom, window.size)
                }
                .animation(.easeOut(duration: 0.15), value: isPresented)
                .accessibilityAddTraits(isPresented ? .isModal : [])
            }
    }
}

extension View {
    /// A card over the window with a veil behind it, a title, and Esc and a close button as the way out. Every modal in the app is this:
    /// a different look or behaviour is a new `size`, `placement` or prop here, not a `.sheet` or an overlay written in a view
    /// (`scripts/check-banned-apis.sh` fails one). Pass `closesOnOutsideClick: false` where a stray click would lose typed text. `accessory`
    /// puts controls beside the close button (a pager, a toggle).
    func modal<Accessory: View, Presented: View>(
        _ title: String, isPresented: Binding<Bool>, size: ModalSize, placement: ModalPlacement = .centered,
        closesOnOutsideClick: Bool = true, @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Presented
    ) -> some View {
        modifier(
            ModalPresentation(
                title: title, isPresented: isPresented, size: size, placement: placement,
                closesOnOutsideClick: closesOnOutsideClick, accessory: accessory, presented: content))
    }

    /// The same with nothing beside the close button.
    func modal<Presented: View>(
        _ title: String, isPresented: Binding<Bool>, size: ModalSize, placement: ModalPlacement = .centered,
        closesOnOutsideClick: Bool = true, @ViewBuilder content: @escaping () -> Presented
    ) -> some View {
        modal(
            title, isPresented: isPresented, size: size, placement: placement, closesOnOutsideClick: closesOnOutsideClick,
            accessory: { EmptyView() }, content: content)
    }
}
