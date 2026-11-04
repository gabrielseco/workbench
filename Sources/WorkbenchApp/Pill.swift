import SwiftUI

/// How a pill is filled: a wash of its tone, a raised panel with a hairline, or a grey control that answers the pointer.
enum PillStyle {
    case tinted
    case outlined
    /// A button shaped as a pill: grey, a step darker under the pointer and darker again while what it opens is open.
    case control(hovered: Bool, selected: Bool)
}

/// A pill's measurements: `small` sits in a row of text or a header, `regular` stands in a toolbar.
enum PillSize {
    case small
    case regular
    case large

    var style: TextStyle {
        switch self {
        case .small: .captionMedium
        case .regular: .callout
        case .large: .body
        }
    }
    var horizontalPadding: CGFloat {
        switch self {
        case .small: Space.s
        case .regular: Space.m
        case .large: Space.m
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small: Space.xxs
        case .regular: Space.xs
        case .large: Space.xs
        }
    }
}

extension View {
    /// A capsule around a short label. A tinted pill takes its text and wash from `tone` (one strength, 0.12); an outlined one leaves the text
    /// colour to the caller. A font set on the content wins over the size's. A new look is a new `PillStyle` or `PillSize`, not a copy.
    func pill(_ tone: Color = Theme.grey, style: PillStyle = .tinted, size: PillSize = .small) -> some View {
        textStyle(size.style).padding(.horizontal, size.horizontalPadding).padding(.vertical, size.verticalPadding)
            .modifier(PillFill(tone: tone, style: style))
    }
}

private struct PillFill: ViewModifier {
    var tone: Color
    var style: PillStyle

    func body(content: Content) -> some View {
        switch style {
        case .tinted: content.foregroundStyle(tone).background(tone.opacity(0.12), in: Capsule())
        case .outlined: content.background(Theme.panel, in: Capsule()).overlay(Capsule().stroke(Theme.line))
        case .control(let hovered, let selected):
            content.background(Theme.grey.opacity(selected ? 0.2 : hovered ? 0.14 : 0.08), in: Capsule()).contentShape(Capsule())
        }
    }
}
