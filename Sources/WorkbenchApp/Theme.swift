import AppKit
import SwiftUI
import WorkbenchCore

/// Colour has four meanings and no others (docs/plan/P19-swiftui-app.md): blue is working or your current step, green is
/// done, grey is not yet, amber is "the thread cannot go on until you decide". Red is for something broken, never "needs you".
enum Theme {
    enum Token: CaseIterable { case blue, green, amber, red, grey, rail, canvas, raised, panel, line, fg2, fg3, inv, invfg }

    /// The design's palette (docs/design/chat-feed, PARITY.md): one value for each appearance, as 0xRRGGBB.
    private struct Swatch {
        var light: UInt32
        var dark: UInt32
    }

    private static let swatches: [Token: Swatch] = [
        .blue: Swatch(light: 0x1f5fd1, dark: 0x5b9dff),
        .green: Swatch(light: 0x1b7f4e, dark: 0x4cc38a),
        .amber: Swatch(light: 0xa35f00, dark: 0xf0b04a),
        .red: Swatch(light: 0xc8322a, dark: 0xf2685f),
        .grey: Swatch(light: 0x667084, dark: 0x7e8695),
        .rail: Swatch(light: 0xeceef2, dark: 0x1b1e24),
        .canvas: Swatch(light: 0xf4f5f8, dark: 0x16191e),
        .raised: Swatch(light: 0xe1e5ec, dark: 0x2a2f39),
        .panel: Swatch(light: 0xffffff, dark: 0x21252d),
        .line: Swatch(light: 0xd3d8e0, dark: 0x323844),
        .fg2: Swatch(light: 0x454d5d, dark: 0xb0b7c4),
        .fg3: Swatch(light: 0x5d667a, dark: 0x919aaa),
        .inv: Swatch(light: 0x1b1f27, dark: 0xeef0f4),
        .invfg: Swatch(light: 0xf4f5f8, dark: 0x14171c),
    ]

    /// A token's value for an appearance, as sRGB 0...1. Pure, so a test can read both appearances.
    static func rgb(_ token: Token, dark: Bool) -> [Double] {
        guard let swatch = swatches[token] else { return [] }
        let value = dark ? swatch.dark : swatch.light
        return [Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255]
    }

    /// One colour for each appearance, so a label is readable on the light rail and on the dark one.
    private static func adaptive(_ token: Token) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let rgb = rgb(token, dark: dark)
                guard rgb.count == 3 else { return .windowBackgroundColor }
                return NSColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
            })
    }

    static var blue: Color { adaptive(.blue) }
    static var green: Color { adaptive(.green) }
    static var amber: Color { adaptive(.amber) }
    static var red: Color { adaptive(.red) }
    static var grey: Color { adaptive(.grey) }
    /// The rail's background, set here so it is the same in any render.
    static var rail: Color { adaptive(.rail) }
    /// A raised surface: the person's bubble, the avatar's disc.
    static var raised: Color { adaptive(.raised) }
    /// A panel: the chat's composer.
    static var panel: Color { adaptive(.panel) }
    /// A hairline border.
    static var line: Color { adaptive(.line) }
    /// The artboards' second and third text colours: a step that is done, and one still to come. Readable on the canvas in both appearances,
    /// which the system's `.tertiary` is not on the light one.
    static var fg2: Color { adaptive(.fg2) }
    static var fg3: Color { adaptive(.fg3) }
    /// The artboards' inverse pair: the primary button's fill and its label, and the switches' on-track. Neutral, so it takes none of the
    /// state colours' meanings.
    static var inv: Color { adaptive(.inv) }
    static var invfg: Color { adaptive(.invfg) }
    /// What the thread screens sit on: the design's `--bg`.
    static var canvas: Color { adaptive(.canvas) }

    static func color(for mark: SpineMark) -> Color {
        switch mark {
        case .done: green
        case .current: blue
        case .needsYou: amber
        case .pending: grey
        case .failed: red
        }
    }
}

extension SpineMark {
    var symbol: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .current: "circle.inset.filled"
        case .needsYou: "exclamationmark.circle.fill"
        case .pending: "circle"
        case .failed: "xmark.circle.fill"
        }
    }
}
