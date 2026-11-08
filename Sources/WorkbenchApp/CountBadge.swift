import SwiftUI

/// The mark a project tile carries when something in the project asks for you: a number on amber (needs you) or red (failed), or a blue
/// dot while a run is going. Its ring is the rail's own colour, so it reads as cut out of the tile.
struct CountBadge: View {
    enum Kind: Equatable {
        case needsYou(Int)
        case failed(Int)
        case running

        init?(_ badge: RailBadge) {
            switch badge {
            case .none: return nil
            case .running: self = .running
            case .needsYou(let count): self = .needsYou(count)
            case .failed(let count): self = .failed(count)
            }
        }
    }

    var kind: Kind

    private static let size: CGFloat = 18
    private static let dot: CGFloat = 14
    private static let ring: CGFloat = 2

    /// `99+` rather than a number too wide for the tile's corner.
    static func text(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

    var body: some View {
        switch kind {
        case .needsYou(let count): number(count, Theme.amber)
        case .failed(let count): number(count, Theme.red)
        case .running:
            Circle().fill(Theme.blue).frame(width: Self.dot, height: Self.dot)
                .overlay(Circle().strokeBorder(Theme.rail, lineWidth: Self.ring))
        }
    }

    private func number(_ count: Int, _ tone: Color) -> some View {
        Text(Self.text(count)).textStyle(.captionBold).foregroundStyle(Theme.invfg).lineLimit(1)
            .padding(.horizontal, Space.xs).frame(minWidth: Self.size, minHeight: Self.size)
            .background(tone, in: Capsule()).overlay(Capsule().strokeBorder(Theme.rail, lineWidth: Self.ring))
    }
}
