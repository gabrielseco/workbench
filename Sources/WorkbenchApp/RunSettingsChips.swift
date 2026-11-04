import SwiftUI

/// A small rounded label: an allowed tool, or the count of the rest.
struct Chip: View {
    var text: String
    var mono: Bool

    var body: some View {
        Text(text).textStyle(mono ? .chipMono : .chip, .muted)
            .lineLimit(1).truncationMode(.middle).pill(style: .outlined)
    }
}

/// Children laid out left to right and wrapped to the next line when the width runs out, as the artboard's tool chips are.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            // A chip wider than the row is given the row's width and truncates its text, so nothing leaves the panel.
            let proposed = ProposedViewSize(width: bounds.width, height: nil)
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: proposed)
        }
    }

    /// Where each child goes and how big the whole is: pure, so a test can read it.
    func layout(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        let proposal = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        return FlowLayout.arrange(sizes: subviews.map { $0.sizeThatFits(proposal) }, width: width, spacing: spacing)
    }

    static func arrange(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var (x, y, rowHeight, widest) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        for natural in sizes {
            // No chip is wider than the row.
            let size = CGSize(width: min(natural.width, width), height: natural.height)
            if x > 0, x + size.width > width {
                (x, y, rowHeight) = (0, y + rowHeight + spacing, 0)
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
