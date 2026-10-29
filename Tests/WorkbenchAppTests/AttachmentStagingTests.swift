import AppKit
import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct AttachmentStagingTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("staging-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real, tiny image: what a screenshot is, as TIFF (what the clipboard carries) and as PNG.
    private func picture() throws -> (tiff: Data, png: Data) {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        return (tiff, png)
    }

    private func file(_ name: String, _ data: Data, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func anImageFileIsCopiedSoMovingTheOriginalChangesNothing() async throws {
        let dir = try folder()
        let original = try file("shot.png", try picture().png, in: dir)
        let staging = AttachmentStaging()
        await staging.add(files: [original])
        #expect(staging.items.count == 1 && staging.problem == nil)
        try FileManager.default.removeItem(at: original)
        let copy = try #require(staging.urls.first)
        #expect(FileManager.default.fileExists(atPath: copy.path) && copy.pathExtension == "png")
        staging.clear()
        #expect(!FileManager.default.fileExists(atPath: copy.path) && staging.items.isEmpty)
    }

    @Test func somethingThatIsNotAnImageIsRefusedWithWhyAndNotAdded() async throws {
        let dir = try folder()
        let text = try file("notes.png", Data("hello".utf8), in: dir)
        let staging = AttachmentStaging()
        await staging.add(files: [text])
        #expect(staging.items.isEmpty && staging.problem?.contains("notes.png is not a PNG") == true)
    }

    @Test func theSixthImageIsRefusedAndTheFirstFiveStay() async throws {
        let dir = try folder()
        let png = try picture().png
        let files = try (0..<6).map { try file("s\($0).png", png, in: dir) }
        let staging = AttachmentStaging()
        await staging.add(files: files)
        #expect(staging.items.count == GoalAttachments.maxCount)
        #expect(staging.problem == "\(GoalAttachments.Refusal.tooMany)")
    }

    @Test func aScreenshotOnTheClipboardBecomesAPNG() async throws {
        let staging = AttachmentStaging()
        await staging.add(imageData: try picture().tiff)
        let kept = try #require(staging.urls.first)
        #expect(kept.pathExtension == "png" && staging.problem == nil)
        #expect(try GoalAttachments.load(kept).ext == "png", "what was kept reads back as a PNG")
        await staging.add(imageData: Data("nope".utf8))
        #expect(staging.items.count == 1 && staging.problem == "That is not an image.")
        staging.clear()
    }

    @Test func pastingTakesImagesAndLeavesTextForTheTextField() async throws {
        let staging = AttachmentStaging()
        let board = NSPasteboard(name: NSPasteboard.Name("workbench-test-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("some words", forType: .string)
        let textTaken = await staging.add(from: board)
        #expect(textTaken == false && staging.items.isEmpty, "plain text is not ours")

        board.clearContents()
        board.setData(try picture().tiff, forType: .tiff)
        let pictureTaken = await staging.add(from: board)
        #expect(pictureTaken && staging.items.count == 1)

        let dir = try folder()
        board.clearContents()
        board.writeObjects([try file("a.png", try picture().png, in: dir) as NSURL])
        let fileTaken = await staging.add(from: board)
        #expect(fileTaken && staging.items.count == 2)
        staging.clear()
    }

    @Test func aPasteIsForTheScreenshotsOnlyWhenTheClipboardHoldsAnImageAndNoText() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("workbench-test-\(UUID().uuidString)"))
        board.clearContents()
        #expect(!AttachmentStaging.wantsImages(board), "empty")
        board.setString("words", forType: .string)
        #expect(!AttachmentStaging.wantsImages(board))
        board.clearContents()
        board.setData(try picture().tiff, forType: .tiff)
        #expect(AttachmentStaging.wantsImages(board))
        board.setString("words", forType: .string)
        #expect(!AttachmentStaging.wantsImages(board), "text and an image: the text field keeps it")
        board.clearContents()
        board.writeObjects([try file("a.png", try picture().png, in: try folder()) as NSURL])
        #expect(AttachmentStaging.wantsImages(board), "an image file")
        board.clearContents()
        board.writeObjects([try file("a.txt", Data("hi".utf8), in: try folder()) as NSURL])
        #expect(!AttachmentStaging.wantsImages(board), "a file that is not an image")
    }

    @Test func aClipboardImageTooBigToReadIsRefusedBeforeAnythingIsDecoded() async throws {
        let staging = AttachmentStaging()
        await staging.add(imageData: try picture().tiff, rawLimit: 10)
        #expect(staging.items.isEmpty && staging.problem == "That image is too large to read.")
    }

    @Test func aCutOffPictureIsRefusedNotAdded() async throws {
        let dir = try folder()
        let cut = try file("cut.png", try picture().png.dropLast(20), in: dir)
        let staging = AttachmentStaging()
        await staging.add(files: [cut])
        #expect(staging.items.isEmpty && staging.problem?.contains("cut.png is not a PNG") == true)
    }

    @Test func eachImageGetsASmallThumbnail() async throws {
        let staging = AttachmentStaging()
        await staging.add(imageData: try picture().tiff)
        let thumbnail = try #require(staging.items.first?.thumbnail)
        #expect(thumbnail.size.width <= CGFloat(AttachmentStaging.thumbnailPixels) && thumbnail.size.width > 0)
        staging.clear()
    }

    @Test func aSheetClearedWhileImagesAreBeingPreparedKeepsNoneAndLeavesNoFiles() async throws {
        let dir = try folder()
        let png = try picture().png
        let files = try (0..<4).map { try file("p\($0).png", png, in: dir) }
        let staging = AttachmentStaging()
        let adding = Task { await staging.add(files: files) }
        await Task.yield()
        #expect(staging.pending > 0, "the first image is still being prepared")
        staging.clear()
        await adding.value
        #expect(staging.items.isEmpty && staging.pending == 0)
        #expect(!FileManager.default.fileExists(atPath: staging.directory.path), "no copy and no folder left behind")
    }

    @Test func nothingIsPendingOnceEveryImageIsInAndTheyKeepTheOrderGiven() async throws {
        let dir = try folder()
        let png = try picture().png
        let files = try (0..<5).map { try file("q\($0).png", png, in: dir) }
        let staging = AttachmentStaging()
        await staging.add(files: files)
        #expect(staging.pending == 0 && staging.items.count == 5)
        let sizes = try staging.urls.map { try Data(contentsOf: $0).count }
        #expect(sizes == Array(repeating: png.count, count: 5))
        staging.clear()
    }

    @Test func aPictureWithNoPictureInItIsRefusedEvenWhenItsShapeIsRight() async throws {
        // A header and an ending, nothing between: core's shape check passes it, decoding does not.
        func be(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * $0)) & 0xFF) } }
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += be(13)
        bytes += Array("IHDR".utf8)
        bytes += be(4)
        bytes += be(4)
        bytes += [8, 2, 0, 0, 0, 0, 0, 0, 0]
        bytes += [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        let hollow = Data(bytes)
        let staging = AttachmentStaging()
        await staging.add(files: [try file("hollow.png", hollow, in: try folder())])
        #expect(staging.items.isEmpty && staging.problem == "hollow.png could not be read as an image.")
    }

    @Test func removingOneKeepsTheOthersInOrder() async throws {
        let png = try picture().png
        let dir = try folder()
        let staging = AttachmentStaging()
        let three = try ["a", "b", "c"].map { try file("\($0).png", png, in: dir) }
        await staging.add(files: three)
        let (first, second, third) = (staging.items[0], staging.items[1], staging.items[2])
        staging.remove(second)
        #expect(staging.items.map(\.id) == [first.id, third.id])
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
        staging.clear()
    }
}
