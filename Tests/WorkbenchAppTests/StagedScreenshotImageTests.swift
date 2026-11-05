import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import WorkbenchApp

@Suite struct StagedScreenshotImageTests {
    /// A PNG of `width` × `height` pixels, written to a file of its own.
    private func png(width: Int, height: Int) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func aScreenshotIsDecodedWholeAndShownAtItsRetinaPointSize() throws {
        let url = try png(width: 1200, height: 800)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try #require(StagedScreenshotImage.decode(url))
        #expect(decoded.image.width == 1200 && decoded.image.height == 800)
        #expect(decoded.points(at: 2) == CGSize(width: 600, height: 400))
        #expect(decoded.points(at: 1) == CGSize(width: 1200, height: 800))
    }

    @Test func aHugeImageCostsABoundedBitmapButKeepsItsSize() throws {
        let url = try png(width: 8000, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try #require(StagedScreenshotImage.decode(url))
        #expect(max(decoded.image.width, decoded.image.height) <= StagedScreenshotImage.maxPixels)
        #expect(decoded.pixels.width == 8000 && abs(decoded.pixels.height - 100) <= 2)
    }

    @Test func aFileThatIsNotAnImageIsNotShown() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).png")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(StagedScreenshotImage.decode(url) == nil)
    }
}
