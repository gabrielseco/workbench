import AppKit
import SwiftUI
import WorkbenchCore

/// Colour has four meanings and no others (docs/plan/P19-swiftui-app.md): blue is working or your current step, green is
/// done, grey is not yet, amber is "the thread cannot go on until you decide". Red is for something broken, never "needs you".
enum Theme {
    static let blue = adaptive(light: [0.12, 0.31, 0.86], dark: [0.45, 0.62, 1.0])
    static let green = adaptive(light: [0.07, 0.53, 0.31], dark: [0.36, 0.80, 0.55])
    static let amber = adaptive(light: [0.80, 0.50, 0.04], dark: [0.98, 0.72, 0.28])
    static let red = adaptive(light: [0.78, 0.16, 0.16], dark: [1.0, 0.47, 0.45])
    static let grey = adaptive(light: [0.56, 0.58, 0.62], dark: [0.62, 0.64, 0.68])

    /// One colour for each appearance, so a label is readable on the light rail and on the dark one.
    private static func adaptive(light: [Double], dark: [Double]) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
            })
    }

    /// The rail's background: a light grey in light mode and a dark one in dark mode, set here so it is the same in any render.
    static let rail = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.14, alpha: 1) : NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
        })

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
