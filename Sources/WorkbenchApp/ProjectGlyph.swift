import SwiftUI

/// What a project's picture is made of, chosen by a hash of its path (FNV-1a, not Swift's per-launch `hashValue`): the same folder always
/// gets the same picture, so a person learns a tile by its shape. An outline (circle, square, diamond, hexagon), drawn filled or as a ring,
/// and a small mirrored 3 x 3 mark inside it. One ink, no colour: blue, green, amber and red are states (docs/DESIGN.md).
struct ProjectGlyphSpec: Equatable {
    enum Outline: Int, CaseIterable { case circle, square, diamond, hexagon }

    var outline: Outline
    /// A ring with the mark filled, rather than a solid shape with the mark cut out of it.
    var ring: Bool
    /// `marks[row][column]`, mirrored left to right.
    var marks: [[Bool]]

    private static let marksPerSide = 3
    /// One cell or a block, and the mark reads as nothing; so the hash is run again.
    private static let markCount = 3...6

    /// Pure and total.
    static func of(path: String) -> ProjectGlyphSpec {
        var state = fnv1a(path)
        var spec = make(state)
        for _ in 0..<16 where !markCount.contains(spec.marks.joined().filter { $0 }.count) {
            state = fnv1a(String(state))
            spec = make(state)
        }
        return spec
    }

    private static func make(_ bits: UInt64) -> ProjectGlyphSpec {
        let outlines = Outline.allCases
        let marks = (0..<marksPerSide).map { row -> [Bool] in
            let edge = bits >> UInt64(8 + row * 2) & 1 == 1
            let middle = bits >> UInt64(9 + row * 2) & 1 == 1
            return [edge, middle, edge]
        }
        return ProjectGlyphSpec(outline: outlines[Int(bits % UInt64(outlines.count))], ring: bits >> 4 & 1 == 1, marks: marks)
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

private struct OutlineShape: Shape {
    var outline: ProjectGlyphSpec.Outline

    func path(in rect: CGRect) -> Path {
        switch outline {
        case .circle: return Path(ellipseIn: rect)
        case .square: return Path(roundedRect: rect, cornerRadius: rect.width * 0.22)
        case .diamond: return polygon(in: rect, [(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)])
        case .hexagon: return polygon(in: rect, [(0.25, 0.03), (0.75, 0.03), (1, 0.5), (0.75, 0.97), (0.25, 0.97), (0, 0.5)])
        }
    }

    private func polygon(in rect: CGRect, _ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        let mapped = points.map { CGPoint(x: rect.minX + $0.0 * rect.width, y: rect.minY + $0.1 * rect.height) }
        path.addLines(mapped)
        path.closeSubpath()
        return path
    }
}

struct ProjectGlyph: View {
    var path: String
    var size: CGFloat = 30

    var body: some View {
        let spec = ProjectGlyphSpec.of(path: path)
        Canvas { context, canvas in
            let whole = CGRect(origin: .zero, size: canvas)
            let shape = OutlineShape(outline: spec.outline).path(in: whole.insetBy(dx: 1, dy: 1))
            let inner = whole.insetBy(dx: canvas.width * 0.3, dy: canvas.height * 0.3)
            let step = inner.width / 3
            var marks = Path()
            for (row, line) in spec.marks.enumerated() {
                for (column, on) in line.enumerated() where on {
                    let origin = CGPoint(x: inner.minX + CGFloat(column) * step, y: inner.minY + CGFloat(row) * step)
                    let cell = CGRect(origin: origin, size: CGSize(width: step, height: step)).insetBy(dx: 0.5, dy: 0.5)
                    marks.addRoundedRect(in: cell, cornerSize: CGSize(width: 1.5, height: 1.5))
                }
            }
            if spec.ring {
                context.stroke(shape, with: .foreground, lineWidth: 2)
                context.fill(marks, with: .foreground)
            } else {
                context.fill(shape, with: .foreground)
                context.blendMode = .destinationOut
                context.fill(marks, with: .color(.black))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
