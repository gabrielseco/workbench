import SwiftUI

/// The spacing scale on a 4 pt grid: every padding and every stack gap in a view is one of these. A view never writes a number there; an
/// off-grid value rounds to the nearest step (a tie goes up), and a step the scale lacks is a new case here, decided once.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
    static let huge: CGFloat = 40
    static let giant: CGFloat = 48
}
