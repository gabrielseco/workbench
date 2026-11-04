import SwiftUI
import Testing

@testable import WorkbenchApp

/// The card is one component with a style prop: what each style rounds, and how its line is drawn, is decided here and nowhere else.
@MainActor @Suite struct CardTests {
    @Test func eachStyleRoundsByItsOwnRadius() {
        #expect(CardStyle.panel.radius == Radius.card && Radius.card == 12)
        #expect(CardStyle.popover.radius == Radius.popover && Radius.popover == 14)
        #expect(CardStyle.overlay.radius == Radius.overlay && Radius.overlay == 18)
    }

    @Test func aPanelsLineIsCentredOnItsEdgeAndTheSystemCardsAreInsideIt() {
        #expect(!CardStyle.panel.hairlineInside)
        #expect(CardStyle.popover.hairlineInside && CardStyle.overlay.hairlineInside)
    }

    @Test func theModifierTakesAStyleAStateAndWhetherToClip() {
        let plain = String(describing: Text("x").card())
        let focused = String(describing: Text("x").card(stroke: Theme.blue, strokeWidth: 1.5, clips: true))
        #expect(plain.contains("CardSurface") && focused.contains("CardSurface"))
        #expect(plain.contains("clips: false") && focused.contains("clips: true"))
        #expect(focused.contains("strokeWidth: 1.5"))
    }
}
