import SwiftUI

/// The two insets that repeat as design constants: the gutter a screen's column keeps from the window's edge, and the inset inside a card's rows.
/// Other gaps are one-off and stay where they are used.
enum Spacing {
    static let gutter: CGFloat = Space.xxxl
    static let inset: CGFloat = Space.l
}

/// The corner radii the app uses, by what they round. A view names one of these (or takes a component that does) instead of a number.
enum Radius {
    /// A box inside a screen: a callout, an outlined control.
    static let box: CGFloat = 8
    /// A control: a button, an icon button.
    static let control: CGFloat = 7
    /// A picture cut to a rounded rectangle.
    static let thumbnail: CGFloat = 6
    /// A softer box the classic goal screens and a person's note sit in.
    static let quiet: CGFloat = 10
    static let card: CGFloat = 12
    static let popover: CGFloat = 14
    static let overlay: CGFloat = 18
}

/// Which surface a card is. Each has its own fill, radius and hairline; the content and the padding inside are the caller's.
enum CardStyle {
    /// A panel on the thread screens: the goal, the decision, the run, the composer.
    case panel
    /// A popover card (the project picker).
    case popover
    /// The modal card laid over the window.
    case overlay

    var radius: CGFloat {
        switch self {
        case .panel: Radius.card
        case .popover: Radius.popover
        case .overlay: Radius.overlay
        }
    }

    var fill: Color { self == .panel ? Theme.panel : Color(nsColor: .controlBackgroundColor) }
    var hairline: Color { self == .panel ? Theme.line : Color.primary.opacity(0.1) }
    /// A panel's line is drawn centred on its edge, the system cards' inside it, as each was drawn before this was one component.
    var hairlineInside: Bool { self != .panel }
}

struct CardSurface: ViewModifier {
    var style: CardStyle
    var stroke: Color?
    var strokeWidth: CGFloat
    var clips: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radius)
        let line = stroke ?? style.hairline
        let surface = content
            .background(style.fill, in: shape)
            .overlay {
                if style.hairlineInside {
                    shape.strokeBorder(line, lineWidth: strokeWidth)
                } else {
                    shape.stroke(line, lineWidth: strokeWidth)
                }
            }
        if clips { surface.clipShape(shape) } else { surface }
    }
}

extension View {
    /// A card: the surface's fill, radius and hairline around this content. `stroke` and `strokeWidth` carry a state (focus, a warning);
    /// `clips` cuts the content to the corners (a card whose rows reach the edge). A new card look is a new `CardStyle`, not a copy.
    func card(_ style: CardStyle = .panel, stroke: Color? = nil, strokeWidth: CGFloat = 1, clips: Bool = false) -> some View {
        modifier(CardSurface(style: style, stroke: stroke, strokeWidth: strokeWidth, clips: clips))
    }
}
