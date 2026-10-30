import SwiftUI

/// Puts a card over the whole window while `shown`. The layer takes every click, and a click outside the card closes nothing:
/// half-written text is not lost to a stray one. The card's own Cancel, Esc and close button do. New goal and Send back both
/// stand on it, so the two look and behave alike.
struct OverlayLayer<Card: View>: View {
    var shown: Bool
    @ViewBuilder var card: () -> Card

    var body: some View {
        ZStack(alignment: .top) {
            if shown {
                Color.black.opacity(0.32).contentShape(Rectangle()).onTapGesture {}.transition(.opacity)
                card().padding(.top, 52).transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: shown)
        .accessibilityAddTraits(shown ? .isModal : [])
    }
}

extension View {
    /// The card's frame: width, rounded background, hairline and shadow.
    func overlayCard() -> some View {
        padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 22)
            .frame(width: 600)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.35), radius: 32, y: 14)
    }
}
