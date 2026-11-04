import SwiftUI
import Testing

@testable import WorkbenchApp

/// The type scale and the tones are the only place a font or a text colour is named; a view picks a step.
@MainActor @Suite(.serialized) struct TextStyleTests {
    private func width(_ step: TextStyle) -> Int? { size(step).map { $0.width * 100 + $0.height } }

    private func size(_ step: TextStyle) -> (width: Int, height: Int)? {
        let renderer = ImageRenderer(content: Text("Hamburgefonstiv 0123").textStyle(step))
        renderer.scale = 1
        return renderer.cgImage.map { ($0.width, $0.height) }
    }

    @Test func everyStepOfTheScaleDrawsDifferentText() throws {
        let steps: [TextStyle] = [
            .display, .title, .section, .heading, .body, .bodyMedium, .bodyStrong, .serifBody, .serifLarge, .callout,
            .calloutStrong,
            .subheadline, .caption, .captionMedium, .captionStrong, .captionBold, .mono, .monoCallout, .chip, .chipMono,
        ]
        let widths = try steps.map { try #require(width($0)) }
        #expect(Set(widths).count == steps.count, "two steps draw the same text: \(widths)")
    }

    @Test func aBiggerStepIsWiderAndAStrongOneIsWiderThanItsPlainOne() throws {
        #expect(try #require(size(.title)).width > #require(size(.heading)).width)
        #expect(try #require(size(.heading)).width > #require(size(.callout)).width)
        #expect(try #require(size(.calloutStrong)).width > #require(size(.callout)).width)
        #expect(try #require(size(.captionStrong)).width > #require(size(.caption)).width)
    }

    @Test func theTonesAreTheStateColoursAndTheSystemLevels() {
        #expect(TextTone.primary.color == .primary && TextTone.secondary.color == .secondary)
        let state = Color(red: 0.2, green: 0.4, blue: 0.6)
        #expect(TextTone.state(state).color == state)
    }

    /// The colour of the first opaque pixel of a big glyph, as (red, green, blue).
    private func ink(_ tone: TextTone) -> [Int]? {
        let content = Text("\u{2588}\u{2588}\u{2588}").textStyle(.display, tone).padding(4)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        for start in stride(from: 0, to: bytes.count - 3, by: 4) where bytes[start + 3] > 240 {
            return [Int(bytes[start]), Int(bytes[start + 1]), Int(bytes[start + 2])]
        }
        return nil
    }

    @Test func aToneColoursTheTextItIsGivenTo() throws {
        let red = try #require(ink(.red))
        let blue = try #require(ink(.blue))
        let green = try #require(ink(.green))
        #expect(red[0] > red[1] + 60 && red[0] > red[2] + 60, "red: \(red)")
        #expect(blue[2] > blue[0] + 40, "blue: \(blue)")
        #expect(green[1] > green[0] + 30, "green: \(green)")
    }
}
