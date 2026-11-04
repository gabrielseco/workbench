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

    /// The alpha of the pixel at (x, y) of a 60 x 60 red square wrapped in a card; nil if it could not be drawn.
    private func alpha(clips: Bool, x: Int, y: Int) -> Double? {
        let view = Color.red.frame(width: 60, height: 60).card(.panel, clips: clips)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        let alphaFirst = [CGImageAlphaInfo.premultipliedFirst, .first, .noneSkipFirst].contains(image.alphaInfo)
        return Double(bytes[offset + (alphaFirst ? 0 : 3)]) / 255
    }

    @Test func clippingCutsTheContentToTheCornersAndNotClippingLeavesIt() throws {
        let clipped = try #require(alpha(clips: true, x: 0, y: 0))
        let open = try #require(alpha(clips: false, x: 0, y: 0))
        #expect(clipped < 0.1, "the corner is rounded away")
        #expect(open > 0.9, "without clips the content reaches the corner")
        #expect(try #require(alpha(clips: true, x: 30, y: 30)) > 0.9, "the middle is untouched")
    }
}
