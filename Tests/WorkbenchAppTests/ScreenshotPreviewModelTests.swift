import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import WorkbenchApp

/// What the screenshot preview decides before it draws: its title, paging, staleness and the area it asks for.
@MainActor @Suite struct ScreenshotPreviewModelTests {
    private func shots(_ count: Int) -> [ProofShot] {
        (1...count).map { ProofShot(url: URL(fileURLWithPath: "/t/shot-\($0).png"), caption: "Shot \($0)") }
    }

    @Test func theVerifiersScreenshotsPageAndTheTitleSaysWhereYouAre() {
        let model = ScreenshotPreviewModel.proof(shots(3), at: 1)
        #expect(model.title == "Shot 2 · 2 of 3" && model.isPaged && model.needsFeed)
        model.go(2)
        #expect(model.title == "Shot 3 · 3 of 3")
        model.go(9)
        #expect(model.index == 2, "paging stops at the last")
        model.go(-4)
        #expect(model.index == 0, "and at the first")
    }

    @Test func aLoneProofIsNamedByItsCaptionAndNotPaged() {
        let model = ScreenshotPreviewModel.proof(shots(1), at: 0)
        #expect(model.title == "Shot 1" && !model.isPaged)
        #expect(ScreenshotPreviewModel.proof(shots(2), at: 7).index == 1, "an index past the end opens the last")
    }

    @Test func pagingKeepsThePictureOnScreenUntilTheNextIsDecodedAndDropsTheZoom() async throws {
        let (small, big) = (try png(width: 600, height: 400), try png(width: 900, height: 700))
        defer { [small, big].forEach { try? FileManager.default.removeItem(at: $0) } }
        let model = ScreenshotPreviewModel.proof([ProofShot(url: small, caption: "A"), ProofShot(url: big, caption: "B")], at: 0)
        await model.load()
        #expect(model.decoded?.pixels == CGSize(width: 600, height: 400))
        model.actualSize = true
        // The next one was decoded ahead, so the step shows it at once and the card is not sized to its waiting state in between.
        model.go(1)
        #expect(model.decoded?.pixels == CGSize(width: 900, height: 700) && !model.actualSize)
    }

    @Test func aPictureNotDecodedAheadLeavesTheOneBeforeInPlaceInsteadOfAnEmptyCard() async throws {
        let sizes = [(600, 400), (900, 700), (700, 500)]
        let files = try sizes.map { try png(width: $0.0, height: $0.1) }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let model = ScreenshotPreviewModel.proof(files.map { ProofShot(url: $0, caption: "S") }, at: 0)
        await model.load()
        // The third is two steps away, so it was not decoded ahead: the first stays until the third is decoded.
        model.go(2)
        #expect(model.decoded?.pixels == CGSize(width: 600, height: 400) && !model.missing)
        #expect(model.area(scale: 1, room: CGSize(width: 2000, height: 2000)) != ScreenshotPreviewModel.smallest)
        await model.load()
        #expect(model.decoded?.pixels == CGSize(width: 700, height: 500))
    }

    @Test func aStagedScreenshotIsNumberedAmongItsSiblingsAndGoesStaleWhenItIsRemoved() async throws {
        let staging = AttachmentStaging()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var files: [URL] = []
        for name in ["a", "b"] {
            let url = dir.appendingPathComponent("\(name).png")
            try Data(base64Encoded: Self.pixel)!.write(to: url)
            files.append(url)
        }
        await staging.add(files: files)
        try #require(staging.items.count == 2)
        let model = ScreenshotPreviewModel.staged(staging, staging.items[1], number: 2)
        #expect(model.title == "Screenshot 2 of 2" && !model.needsFeed && model.note != nil)
        #expect(!model.isStale)
        staging.remove(staging.items[1])
        #expect(model.isStale, "a screenshot that is no longer staged is not previewed")
    }

    /// A PNG of `width` × `height` pixels in a file of its own.
    private func png(width: Int, height: Int) throws -> URL {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-model-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func theRoomIsTheWindowsAndNotTheScreensSoACardNeverOverflowsASmallWindow() async throws {
        let window = CGSize(width: 900, height: 600)
        let room = ScreenshotPreviewModel.room(in: window)
        #expect(room.width < window.width && room.height < window.height, "a margin, the card's padding and its header come out")
        let url = try png(width: 3000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = ScreenshotPreviewModel.proof([ProofShot(url: url, caption: "Big")], at: 0)
        #expect(model.area(scale: 1, room: room) == ScreenshotPreviewModel.smallest, "before it is decoded")
        await model.load()
        #expect(model.decoded != nil)
        let area = model.area(scale: 1, room: room)
        #expect(area.width <= room.width && area.height <= room.height, "a picture bigger than the window is bounded by it")
        #expect(!model.fits(scale: 1, room: room), "so the toggle to its actual size is offered")
    }

    @Test func aSmallPictureKeepsItsOwnSizeButNeverShrinksBelowTheLeast() async throws {
        let room = ScreenshotPreviewModel.room(in: CGSize(width: 1400, height: 900))
        let url = try png(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = ScreenshotPreviewModel.proof([ProofShot(url: url, caption: "Small")], at: 0)
        await model.load()
        let area = model.area(scale: 2, room: room)
        #expect(area == ScreenshotPreviewModel.smallest, "200 × 150 points is under the least, so the area is the least")
        #expect(model.fits(scale: 2, room: room))
        let wide = try png(width: 1600, height: 1000)
        defer { try? FileManager.default.removeItem(at: wide) }
        let other = ScreenshotPreviewModel.proof([ProofShot(url: wide, caption: "Wide")], at: 0)
        await other.load()
        #expect(other.area(scale: 2, room: room) == CGSize(width: 800, height: 500), "800 × 500 points fits whole")
    }

    @Test func pagingBetweenShotsOfDifferentSizesAndShapesKeepsTheSameArea() async throws {
        let sizes = [(600, 400), (500, 1400), (1600, 300), (300, 200)]
        let files = try sizes.map { try png(width: $0.0, height: $0.1) }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let model = ScreenshotPreviewModel.proof(files.map { ProofShot(url: $0, caption: "S") }, at: 0)
        let room = CGSize(width: 2000, height: 2000)
        await model.load()
        let first = model.area(scale: 1, room: room)
        #expect(first == CGSize(width: 1600, height: 1400), "the widest and the tallest shot both fit whole")
        for index in files.indices {
            model.go(index)
            #expect(model.area(scale: 1, room: room) == first, "page \(index + 1) before it is decoded")
            await model.load()
            #expect(model.area(scale: 1, room: room) == first, "page \(index + 1) once it is decoded")
        }
    }

    @Test func aSetLargerThanTheWindowIsBoundedByItOnEveryPage() async throws {
        let files = try [(4000, 800), (700, 3500)].map { try png(width: $0.0, height: $0.1) }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let model = ScreenshotPreviewModel.proof(files.map { ProofShot(url: $0, caption: "S") }, at: 0)
        let room = ScreenshotPreviewModel.room(in: CGSize(width: 1200, height: 800))
        await model.load()
        #expect(model.area(scale: 1, room: room) == room, "a shot too wide and one too tall: the area is the room")
        #expect(!model.fits(scale: 1, room: room))
        model.go(1)
        await model.load()
        #expect(model.area(scale: 1, room: room) == room && !model.fits(scale: 1, room: room))
    }

    @Test func aShotThatCannotBeReadDoesNotSizeTheSet() async throws {
        let file = try png(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: file) }
        let gone = URL(fileURLWithPath: "/t/missing-\(UUID().uuidString).png")
        let model = ScreenshotPreviewModel.proof([ProofShot(url: file, caption: "A"), ProofShot(url: gone, caption: "B")], at: 0)
        await model.load()
        #expect(model.area(scale: 1, room: CGSize(width: 2000, height: 2000)) == CGSize(width: 800, height: 600))
    }

    /// A 1 × 1 PNG.
    private static let pixel =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
}
