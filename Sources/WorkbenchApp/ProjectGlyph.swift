import SwiftUI

/// A project's picture on the rail: a 5 x 5 grid, mirrored left to right, whose cells come from a hash of the project's path. The same
/// folder always gets the same picture (the hash is FNV-1a, not Swift's per-launch `hashValue`), so a person learns a tile by its shape.
/// One ink, no colour: blue, green, amber and red are states (docs/DESIGN.md), so a project cannot own one.
enum ProjectGlyphCells {
    static let side = 5
    /// Columns drawn from the hash; the rest mirror them.
    private static let half = (side + 1) / 2
    /// A picture with fewer or more cells than this reads as a blank or a block, so the hash is run again.
    private static let filled = 8...16

    /// `filled[row][column]` for a project path. Pure and total.
    static func cells(for path: String) -> [[Bool]] {
        var state = fnv1a(path)
        for _ in 0..<16 {
            let grid = grid(from: state)
            if filled.contains(grid.joined().filter { $0 }.count) { return grid }
            state = fnv1a(String(state))
        }
        return grid(from: state)
    }

    private static func grid(from bits: UInt64) -> [[Bool]] {
        (0..<side).map { row in
            let left = (0..<half).map { column in bits >> UInt64(row * half + column) & 1 == 1 }
            return left + left.dropLast().reversed()
        }
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

struct ProjectGlyph: View {
    var path: String
    var size: CGFloat = 24

    var body: some View {
        let cells = ProjectGlyphCells.cells(for: path)
        Canvas { context, canvasSize in
            let step = canvasSize.width / CGFloat(ProjectGlyphCells.side)
            let gap: CGFloat = 1
            for (row, line) in cells.enumerated() {
                for (column, on) in line.enumerated() where on {
                    let origin = CGPoint(x: CGFloat(column) * step + gap / 2, y: CGFloat(row) * step + gap / 2)
                    let rect = CGRect(origin: origin, size: CGSize(width: step - gap, height: step - gap))
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .foreground)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
