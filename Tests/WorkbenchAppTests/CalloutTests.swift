import SwiftUI
import Testing

@testable import WorkbenchApp

/// The callout is one component with a style prop: what each style draws is checked on rendered pixels (a transparent 60 x 60 square).
@MainActor @Suite(.serialized) struct CalloutTests {
    private func alpha(_ style: CalloutStyle, enabled: Bool = true, x: Int, y: Int) -> Double? {
        let view = Color.clear.frame(width: 60, height: 60).callout(style, enabled: enabled)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        let alphaFirst = [CGImageAlphaInfo.premultipliedFirst, .first, .noneSkipFirst].contains(image.alphaInfo)
        return Double(bytes[offset + (alphaFirst ? 0 : 3)]) / 255
    }

    @Test func aTintedNoteFillsItsBoxAtOneLowStrength() throws {
        let inside = try #require(alpha(.tinted(.red), x: 30, y: 30))
        #expect(inside > 0.06 && inside < 0.09, "the one strength, 0.08: \(inside)")
        #expect(try #require(alpha(.tinted(.red), x: 0, y: 0)) < 0.05, "the corner is rounded off")
    }

    @Test func anOutlineDrawsTheEdgeAndLeavesTheInsideEmpty() throws {
        #expect(try #require(alpha(.outlined, x: 30, y: 30)) < 0.02)
        let edge = [alpha(.outlined, x: 30, y: 0), alpha(.outlined, x: 30, y: 1)].compactMap { $0 }.max() ?? 0
        #expect(edge > 0.1, "the hairline is on the edge: \(edge)")
    }

    @Test func aNeutralWellFills() throws {
        #expect(try #require(alpha(.neutral, x: 30, y: 30)) > 0.02)
    }

    /// Every pixel of a 60 x 60 square, so "draws nothing" is compared on the whole picture.
    private func picture(_ view: some View) -> [UInt8]? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let data = renderer.cgImage?.dataProvider?.data else { return nil }
        return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
    }

    @Test func switchedOffItDrawsNothingAtAll() throws {
        let bare = try #require(picture(Color.clear.frame(width: 60, height: 60)))
        #expect(try #require(picture(Color.clear.frame(width: 60, height: 60).callout(.tinted(.red), enabled: false))) == bare)
        #expect(try #require(picture(Color.clear.frame(width: 60, height: 60).callout(.outlined, enabled: false))) == bare)
        #expect(try #require(picture(Color.clear.frame(width: 60, height: 60).callout(.outlined))) != bare, "and on, it does")
    }
}
