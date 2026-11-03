import AppKit
import os
import SwiftUI
import WorkbenchCore

/// Colour has four meanings and no others (docs/plan/P19-swiftui-app.md): blue is working or your current step, green is
/// done, grey is not yet, amber is "the thread cannot go on until you decide". Red is for something broken, never "needs you".
enum Theme {
    /// The design's palette (docs/design/chat-feed, PARITY.md) while the chat feed preview is on; the app's own until P22 slice 7 removes the
    /// old window. Set by the store when the preview is turned on or off, and read when a colour is drawn.
    private static let previewFlag = OSAllocatedUnfairLock(initialState: false)
    static var preview: Bool {
        get { previewFlag.withLock { $0 } }
        set { previewFlag.withLock { $0 = newValue } }
    }

    enum Token: CaseIterable { case blue, green, amber, red, grey, rail, canvas, raised, panel, line, fg2, fg3 }

    /// One token: the design's value for each appearance, and the app's own for the old window where it had one. `old: nil` means the
    /// design's value serves both (the preview's surfaces, which nothing outside the preview draws); `old: []` means the old window sets
    /// no colour there and the system draws it.
    private struct Swatch {
        var light: UInt32
        var dark: UInt32
        var old: (light: [Double], dark: [Double])?
    }

    private static let swatches: [Token: Swatch] = [
        .blue: Swatch(light: 0x1f5fd1, dark: 0x5b9dff, old: ([0.12, 0.31, 0.86], [0.45, 0.62, 1.0])),
        .green: Swatch(light: 0x1b7f4e, dark: 0x4cc38a, old: ([0.07, 0.53, 0.31], [0.36, 0.80, 0.55])),
        .amber: Swatch(light: 0xa35f00, dark: 0xf0b04a, old: ([0.80, 0.50, 0.04], [0.98, 0.72, 0.28])),
        .red: Swatch(light: 0xc8322a, dark: 0xf2685f, old: ([0.78, 0.16, 0.16], [1.0, 0.47, 0.45])),
        .grey: Swatch(light: 0x667084, dark: 0x7e8695, old: ([0.56, 0.58, 0.62], [0.62, 0.64, 0.68])),
        .rail: Swatch(light: 0xeceef2, dark: 0x1b1e24, old: ([0.95, 0.95, 0.97], [0.14, 0.14, 0.14])),
        .canvas: Swatch(light: 0xf4f5f8, dark: 0x16191e, old: ([], [])),
        .raised: Swatch(light: 0xe1e5ec, dark: 0x2a2f39, old: nil),
        .panel: Swatch(light: 0xffffff, dark: 0x21252d, old: nil),
        .line: Swatch(light: 0xd3d8e0, dark: 0x323844, old: nil),
        .fg2: Swatch(light: 0x454d5d, dark: 0xb0b7c4, old: nil),
        .fg3: Swatch(light: 0x5d667a, dark: 0x919aaa, old: nil),
    ]

    /// A token's value for an appearance, as sRGB 0...1. Pure, so a test can read both palettes without touching the flag.
    static func rgb(_ token: Token, dark: Bool, preview: Bool) -> [Double] {
        guard let swatch = swatches[token] else { return [] }
        if !preview, let old = swatch.old { return dark ? old.dark : old.light }
        let value = dark ? swatch.dark : swatch.light
        return [Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255]
    }

    /// One colour for each appearance, so a label is readable on the light rail and on the dark one.
    private static func adaptive(_ token: Token) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let rgb = rgb(token, dark: dark, preview: preview)
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
    /// What the thread screens sit on: the design's `--bg` with the preview on, the system's window background without it.
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
