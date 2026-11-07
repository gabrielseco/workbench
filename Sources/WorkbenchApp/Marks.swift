import SwiftUI

/// How big a status dot is: the thread rail's and the composer's, or the larger one beside a line of body text.
enum DotSize {
    case regular
    case large

    var side: CGFloat { self == .regular ? 9 : 11 }
    /// The wash round a dot that needs the person.
    var halo: CGFloat { 15 }
}

/// A small round mark: a ring, a filled disc, and a wash round it when it needs you. The thread rail's marks, the phase row's and the
/// criteria's are this, not a `Circle()` sized by hand. It is decoration: what it means is said in words beside it.
struct StatusDot: View {
    var tint: Color
    var filled: Bool
    var halo: Bool
    var size: DotSize

    init(_ tint: Color = Theme.grey, filled: Bool = false, halo: Bool = false, size: DotSize = .regular) {
        (self.tint, self.filled, self.halo, self.size) = (tint, filled, halo, size)
    }

    var body: some View {
        Circle().fill(filled ? tint : Color.clear)
            .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
            .frame(width: size.side, height: size.side)
            .background { if halo { Circle().fill(tint.opacity(0.24)).frame(width: size.halo, height: size.halo) } }
            .accessibilityHidden(true)
    }
}

/// The agent's disc beside what it said: a sparkle on a raised round.
struct AgentAvatar: View {
    /// What a line of its text is as tall as, so a one-line reply sits level with the disc.
    static let side: CGFloat = 22

    var body: some View {
        Image(systemName: "sparkle").textStyle(.captionMedium, .secondary).frame(width: Self.side, height: Self.side)
            .background(Theme.raised, in: Circle()).overlay(Circle().stroke(Theme.line))
    }
}
