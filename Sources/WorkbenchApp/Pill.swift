import SwiftUI

/// How a pill is filled: a wash of its tone, or a raised panel with a hairline.
enum PillStyle {
    case tinted
    case outlined
}

/// A pill's measurements: `small` sits in a row of text or a header, `regular` stands in a toolbar.
enum PillSize {
    case small
    case regular

    var style: TextStyle { self == .small ? .captionMedium : .callout }
    var horizontalPadding: CGFloat { self == .small ? 8 : 10 }
    var verticalPadding: CGFloat { self == .small ? 2 : 3 }
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
        }
    }
}
