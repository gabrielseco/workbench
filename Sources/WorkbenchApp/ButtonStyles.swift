import SwiftUI

/// What a button is for. Picks its colours and weight; the size is separate, so any kind comes in any size.
enum ButtonKind {
    /// The screen's one main action: the inverse pill.
    case primary
    /// Anything else that is a button: a raised, bordered button.
    case plain
    /// A symbol alone in a raised, bordered square: the size's height is its side.
    case icon
}

/// A button's measurements. Two buttons side by side are the same size by passing the same `ButtonSize`.
enum ButtonSize {
    /// What the screen's main action uses, and whatever sits beside it.
    case regular
    /// A button on its own in a dense panel.
    case compact
    /// A button in a footer or a popover row, where a compact one would crowd its line.
    case small

    var fontSize: CGFloat { self == .regular ? 13 : (self == .compact ? 12.5 : 12) }
    var horizontalPadding: CGFloat { self == .regular ? 16 : (self == .compact ? 12 : 9) }
    var minHeight: CGFloat { self == .regular ? 34 : (self == .compact ? 30 : 24) }
}

/// The artboards' buttons (design parity 9) as one component: `kind` and `size` in, the same shape, radius and states out.
struct WorkbenchButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize
    var kind: ButtonKind
    var size: ButtonSize
    /// Fills the width and puts the label at the left, as the panel's Open buttons do.
    var fill = false
    /// The app's default style (a `Button` nobody styled) follows `.controlSize(.small)`; one asked for by name keeps the size it was given.
    var followsControlSize = false

    /// The size drawn: `.small` for a default button in a small control, else the one given.
    private var drawnSize: ButtonSize { Self.drawn(size, follows: followsControlSize, controlSize: controlSize) }

    static func drawn(_ size: ButtonSize, follows: Bool, controlSize: ControlSize) -> ButtonSize {
        follows && (controlSize == .small || controlSize == .mini) ? .small : size
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control)
        configuration.label
            .lineLimit(1).fixedSize(horizontal: !fill, vertical: false)
            .font(.system(size: drawnSize.fontSize, weight: kind == .primary ? .semibold : (kind == .icon ? .semibold : .medium)))
            .foregroundStyle(kind == .primary ? AnyShapeStyle(Theme.invfg) : AnyShapeStyle(.primary))
            .padding(.horizontal, kind == .icon ? 0 : drawnSize.horizontalPadding)
            .frame(width: kind == .icon ? drawnSize.minHeight : nil, height: kind == .icon ? drawnSize.minHeight : nil)
            .frame(
                maxWidth: fill ? .infinity : nil, minHeight: kind == .icon ? nil : drawnSize.minHeight,
                alignment: fill ? .leading : .center)
            .background { background(configuration, shape) }
            .overlay { if kind != .primary { shape.stroke(Theme.line) } }
            .opacity(enabled ? 1 : (kind == .primary ? 0.4 : 0.5))
            .contentShape(shape)
    }

    @ViewBuilder private func background(_ configuration: Configuration, _ shape: RoundedRectangle) -> some View {
        switch kind {
        case .primary:
            // Pressed is darker in both appearances (a lower opacity would fade toward the canvas, lighter on the light one).
            shape.fill(Theme.inv).brightness(configuration.isPressed ? -0.2 : 0)
        case .plain, .icon:
            shape.fill(Theme.raised.opacity(configuration.isPressed ? 0.7 : 1))
        }
    }
}

extension View {
    /// The button the screen's one main action uses.
    func primaryButton(size: ButtonSize = .regular) -> some View {
        buttonStyle(WorkbenchButtonStyle(kind: .primary, size: size))
    }

    /// Any other button that is a button (not an icon or a link).
    func plainButton(fill: Bool = false, size: ButtonSize = .compact) -> some View {
        buttonStyle(WorkbenchButtonStyle(kind: .plain, size: size, fill: fill))
    }

    /// A symbol-only button: a raised square, `size` its side (a composer's Send, a "+" beside a title).
    func iconButton(size: ButtonSize = .compact) -> some View {
        buttonStyle(WorkbenchButtonStyle(kind: .icon, size: size))
    }

    /// The look of a `Button` nobody styled, for the whole window: a plain button, small where the control size says so. Set once at the root.
    func defaultButtonStyle() -> some View {
        buttonStyle(WorkbenchButtonStyle(kind: .plain, size: .compact, followsControlSize: true))
    }

    /// A native switch in the artboards' neutral inverse instead of the person's system accent, which collides with the state colours.
    func switchTint() -> some View { tint(Theme.inv) }
}
