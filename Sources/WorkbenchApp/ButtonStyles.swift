import SwiftUI

/// The one place a button's measurements live, so two buttons side by side are the same size by passing the same `ButtonSize`.
enum ButtonSize {
    /// What the screen's main action uses, and whatever sits beside it.
    case regular
    /// A button on its own in a dense panel.
    case compact

    var fontSize: CGFloat { self == .regular ? 13 : 12.5 }
    var horizontalPadding: CGFloat { self == .regular ? 16 : 12 }
    var minHeight: CGFloat { self == .regular ? 34 : 30 }
}

/// The artboards' buttons (design parity 9): the primary one is the inverse pill, the plain one a raised bordered button.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var size = ButtonSize.regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size.fontSize, weight: .semibold))
            .foregroundStyle(Theme.invfg)
            .padding(.horizontal, size.horizontalPadding).frame(minHeight: size.minHeight)
            // Pressed is darker in both appearances (a lower opacity would fade toward the canvas, lighter on the light one).
            .background {
                RoundedRectangle(cornerRadius: 7).fill(Theme.inv).brightness(configuration.isPressed ? -0.2 : 0)
            }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct PlainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    /// Fills the width and puts the label at the left, as the panel's Open buttons do.
    var fill = false
    var size = ButtonSize.compact

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size.fontSize, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, size.horizontalPadding)
            .frame(
                maxWidth: fill ? .infinity : nil, minHeight: size.minHeight, alignment: fill ? .leading : .center)
            .background(Theme.raised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

extension View {
    /// The button the screen's one main action uses.
    func primaryButton(size: ButtonSize = .regular) -> some View { buttonStyle(PrimaryButtonStyle(size: size)) }

    /// Any other button that is a button (not an icon or a link).
    func plainButton(fill: Bool = false, size: ButtonSize = .compact) -> some View {
        buttonStyle(PlainButtonStyle(fill: fill, size: size))
    }

    /// A native switch in the artboards' neutral inverse instead of the person's system accent, which collides with the state colours.
    func switchTint() -> some View { tint(Theme.inv) }
}
