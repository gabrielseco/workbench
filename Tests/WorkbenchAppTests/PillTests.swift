import SwiftUI
import Testing

@testable import WorkbenchApp

/// The pill is one component with style and size props, checked on rendered pixels.
@MainActor @Suite(.serialized) struct PillTests {
    private struct Picture {
        var width: Int
        var height: Int
        var bytes: [UInt8]
    }

    private func render(_ view: some View) -> Picture? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        return Picture(width: image.width, height: image.height, bytes: bytes)
    }

    @Test func aTintedPillWashesItsToneAtOneStrengthAndRoundsItsEnds() throws {
        let picture = try #require(render(Color.clear.frame(width: 80, height: 20).pill(.red)))
        let alpha = { (x: Int, y: Int) in Double(picture.bytes[(y * picture.width + x) * 4 + 3]) / 255 }
        #expect(picture.width > 80 && picture.height > 20, "padding is the component's")
        let middle = alpha(picture.width / 2, picture.height / 2)
        #expect(middle > 0.09 && middle < 0.15, "0.12: \(middle)")
        #expect(alpha(0, 0) < 0.03, "a capsule's corner is empty")
    }

    @Test func anOutlinedPillDrawsAPanelAndAHairline() throws {
        let tinted = try #require(render(Color.clear.frame(width: 80, height: 20).pill(.red)))
        let outlined = try #require(render(Color.clear.frame(width: 80, height: 20).pill(style: .outlined)))
        #expect(tinted.bytes != outlined.bytes)
        let middle = (outlined.height / 2 * outlined.width + outlined.width / 2) * 4 + 3
        #expect(outlined.bytes[middle] > 200, "the panel is opaque")
    }

    @Test func regularIsLargerThanSmall() throws {
        let small = try #require(render(Color.clear.frame(width: 40, height: 10).pill()))
        let regular = try #require(render(Color.clear.frame(width: 40, height: 10).pill(size: .regular)))
        #expect(regular.width > small.width && regular.height > small.height)
    }
}
