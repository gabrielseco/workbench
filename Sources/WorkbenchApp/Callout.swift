import SwiftUI

/// Which box a callout is: a note in a tone, a neutral well, or an outline with no fill.
enum CalloutStyle {
    /// A note, in a state's colour (or grey) at one strength: a goal, a result, a notice.
    case tinted(Color)
    /// A recessed well for text that is read or edited (instructions, a file).
    case neutral
    /// A hairline box with no fill, for a step and what comes next.
    case outlined
    /// A box on the panel colour with a hairline: a block of the goal.
    case panel
    /// A recessed box on the screen's own colour with a hairline: a log or a transcript.
    case well
}

private struct CalloutSurface: ViewModifier {
    var style: CalloutStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.box)
        switch style {
        case .tinted(let tone): content.background(tone.opacity(0.08), in: shape)
        case .neutral: content.background(.quaternary.opacity(0.5), in: shape)
        case .outlined: content.overlay(shape.stroke(Theme.grey.opacity(0.4)))
        case .panel: content.background(Theme.panel, in: shape).overlay(shape.strokeBorder(Theme.line))
        case .well: content.background(Theme.canvas, in: shape).overlay(shape.stroke(Theme.line))
        }
    }
}

extension View {
    /// A box around this content: radius and strength are the component's, the tone and the kind are the caller's. `enabled: false` leaves the
    /// content bare (a compact form of the same control). A new look is a new `CalloutStyle`, not a copy.
    @ViewBuilder func callout(_ style: CalloutStyle = .tinted(Theme.grey), enabled: Bool = true) -> some View {
        if enabled { modifier(CalloutSurface(style: style)) } else { self }
    }
}
