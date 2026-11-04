import SwiftUI
import Testing

@testable import WorkbenchApp

/// A thumbnail is cut to rounded corners, with the hairline only when asked, checked on rendered pixels.
@MainActor @Suite(.serialized) struct ThumbnailTests {
    private func alpha(outlined: Bool, x: Int, y: Int) -> Double? {
        let renderer = ImageRenderer(content: Color.red.frame(width: 60, height: 60).thumbnail(outlined: outlined))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        return Double(bytes[(y * image.width + x) * 4 + 3]) / 255
    }

    @Test func theCornersAreCutAndTheMiddleIsKept() throws {
        #expect(try #require(alpha(outlined: false, x: 0, y: 0)) < 0.1, "the corner is rounded away")
        #expect(try #require(alpha(outlined: false, x: 30, y: 30)) > 0.9)
    }

    @Test func theHairlineIsDrawnOnlyWhenAsked() throws {
        let plain = try #require(alpha(outlined: false, x: 1, y: 30))
        let lined = try #require(alpha(outlined: true, x: 1, y: 30))
        #expect(plain > 0.9 && lined > 0.9, "the edge is opaque either way")
        let strokeless = ImageRenderer(content: Color.red.frame(width: 60, height: 60).thumbnail())
        let stroked = ImageRenderer(content: Color.red.frame(width: 60, height: 60).thumbnail(outlined: true))
        strokeless.scale = 1
        stroked.scale = 1
        #expect(strokeless.cgImage?.dataProvider?.data != stroked.cgImage?.dataProvider?.data, "the hairline changes the picture")
    }
}
