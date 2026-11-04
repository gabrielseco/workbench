import SwiftUI

/// The type scale: every font the app uses, by name. A view never writes a font; it picks a step. A step the scale lacks is a new case here,
/// decided once, not a `.font(...)` in a view (`scripts/check-ui-literals.sh` counts them and fails a PR that adds one).
enum TextStyle {
    /// Screen and sheet titles, and the largest text.
    case display
    case title
    case section
    case heading
    case body
    case bodyMedium
    case bodyStrong
    case serifBody
    case serifLarge
    /// The default size of most rows and sentences.
    case callout
    case calloutStrong
    case subheadline
    case caption
    case captionMedium
    case captionStrong
    case captionBold
    /// Paths, commands and ids.
    case mono
    case monoCallout
    /// The tool chips' 11.5 pt.
    case chipMono
    case chip

    var font: Font {
        switch self {
        case .display: .title.weight(.bold)
        case .title: .title2.weight(.semibold)
        case .section: .title3.weight(.semibold)
        case .heading: .headline
        case .body: .body
        case .bodyMedium: .body.weight(.medium)
        case .bodyStrong: .body.weight(.semibold)
        case .serifBody: .system(size: 16, design: .serif)
        case .serifLarge: .system(size: 17, design: .serif)
        case .callout: .callout
        case .calloutStrong: .callout.weight(.semibold)
        case .subheadline: .subheadline
        case .caption: .caption
        case .captionMedium: .caption.weight(.medium)
        case .captionStrong: .caption.weight(.semibold)
        case .captionBold: .caption.weight(.bold)
        case .mono: .system(.caption, design: .monospaced)
        case .monoCallout: .system(.callout, design: .monospaced)
        case .chipMono: .system(size: 11.5, design: .monospaced)
        case .chip: .system(size: 11.5)
        }
    }
}

/// The text colours: the system's levels and the five state colours, by meaning.
enum TextTone {
    case primary
    case secondary
    case tertiary
    /// The artboards' second and third text colours (a step that is done, and one still to come).
    case muted
    case subtle
    case blue
    case green
    case amber
    case red
    /// A state's colour, for text whose tone is decided at run time.
    case state(Color)

    var color: Color {
        switch self {
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: Color(nsColor: .tertiaryLabelColor)
        case .muted: Theme.fg2
        case .subtle: Theme.fg3
        case .blue: Theme.blue
        case .green: Theme.green
        case .amber: Theme.amber
        case .red: Theme.red
        case .state(let color): color
        }
    }
}

extension View {
    /// The text in a step of the type scale, and in a tone when it has one. This is the only way a view sets a font.
    func textStyle(_ style: TextStyle, _ tone: TextTone? = nil) -> some View {
        modifier(TextStyling(style: style, tone: tone))
    }
}

private struct TextStyling: ViewModifier {
    var style: TextStyle
    var tone: TextTone?

    func body(content: Content) -> some View {
        if let tone { content.font(style.font).foregroundStyle(tone.color) } else { content.font(style.font) }
    }
}
