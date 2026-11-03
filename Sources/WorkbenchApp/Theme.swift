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

    enum Token: CaseIterable { case blue, green, amber, red, grey, rail, canvas }

    /// A token's value for an appearance, as sRGB 0...1. Pure, so a test can read both palettes without touching the flag.
    static func rgb(_ token: Token, dark: Bool, preview: Bool) -> [Double] {
        func hex(_ value: UInt32) -> [Double] {
            [Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255]
        }
        switch (token, dark, preview) {
        case (.blue, false, false): return [0.12, 0.31, 0.86]
        case (.blue, true, false): return [0.45, 0.62, 1.0]
        case (.green, false, false): return [0.07, 0.53, 0.31]
        case (.green, true, false): return [0.36, 0.80, 0.55]
        case (.amber, false, false): return [0.80, 0.50, 0.04]
        case (.amber, true, false): return [0.98, 0.72, 0.28]
        case (.red, false, false): return [0.78, 0.16, 0.16]
        case (.red, true, false): return [1.0, 0.47, 0.45]
        case (.grey, false, false): return [0.56, 0.58, 0.62]
        case (.grey, true, false): return [0.62, 0.64, 0.68]
        case (.rail, false, false): return [0.95, 0.95, 0.97]
        case (.rail, true, false): return [0.14, 0.14, 0.14]
        // The window's own background, which the old window never sets: the system draws it.
        case (.canvas, _, false): return []
        case (.blue, false, true): return hex(0x1f5fd1)
        case (.blue, true, true): return hex(0x5b9dff)
        case (.green, false, true): return hex(0x1b7f4e)
        case (.green, true, true): return hex(0x4cc38a)
        case (.amber, false, true): return hex(0xa35f00)
        case (.amber, true, true): return hex(0xf0b04a)
        case (.red, false, true): return hex(0xc8322a)
        case (.red, true, true): return hex(0xf2685f)
        case (.grey, false, true): return hex(0x667084)
        case (.grey, true, true): return hex(0x7e8695)
        case (.rail, false, true): return hex(0xeceef2)
        case (.rail, true, true): return hex(0x1b1e24)
        case (.canvas, false, true): return hex(0xf4f5f8)
        case (.canvas, true, true): return hex(0x16191e)
        }
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
