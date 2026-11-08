import AppKit
import SwiftUI

/// Where the keys are. A list or a row of tiles is one focus stop (the arrows walk it and select as they go), so selection alone cannot say
/// whether the keys are on it: the ring does, on the selected item, only while the list has focus. It is the system's focus colour, not one
/// of the five meaning colours, so it never reads as "working" or "needs you".
enum FocusRing {
    static let width: CGFloat = 2
    static let color = Color(nsColor: .keyboardFocusIndicatorColor)
}

private struct ListHasKeysKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The focus stop this view sits in has the keys; items in it that are selected draw the ring.
    var listHasKeys: Bool {
        get { self[ListHasKeysKey.self] }
        set { self[ListHasKeysKey.self] = newValue }
    }
}

extension View {
    /// Marks a focus stop's content as holding the keys (or not), for the `focusRing` of the items inside it.
    func listHasKeys(_ focused: Bool) -> some View { environment(\.listHasKeys, focused) }

    /// The focus ring around this view, drawn when `on`. `radius` is the view's own corner (a `Radius` token).
    func focusRing(_ on: Bool, radius: CGFloat) -> some View {
        overlay {
            if on { RoundedRectangle(cornerRadius: radius).strokeBorder(FocusRing.color, lineWidth: FocusRing.width) }
        }
    }
}

/// The selected item of a list draws the ring while the list has the keys; reads the flag the list set.
private struct SelectedFocusRing: ViewModifier {
    var selected: Bool
    var radius: CGFloat
    @Environment(\.listHasKeys) private var listHasKeys

    func body(content: Content) -> some View { content.focusRing(selected && listHasKeys, radius: radius) }
}

extension View {
    func selectedFocusRing(_ selected: Bool, radius: CGFloat) -> some View {
        modifier(SelectedFocusRing(selected: selected, radius: radius))
    }
}
