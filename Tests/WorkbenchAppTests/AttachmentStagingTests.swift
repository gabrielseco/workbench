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

    @Test func anImageFileIsCopiedSoMovingTheOriginalChangesNothing() throws {
        let dir = try folder()
        let original = try file("shot.png", try picture().png, in: dir)
        let staging = AttachmentStaging()
        staging.add(files: [original])
        #expect(staging.items.count == 1 && staging.problem == nil)
        try FileManager.default.removeItem(at: original)
        let copy = try #require(staging.urls.first)
        #expect(FileManager.default.fileExists(atPath: copy.path) && copy.pathExtension == "png")
        staging.clear()
        #expect(!FileManager.default.fileExists(atPath: copy.path) && staging.items.isEmpty)
    }

    @Test func somethingThatIsNotAnImageIsRefusedWithWhyAndNotAdded() throws {
        let dir = try folder()
        let text = try file("notes.png", Data("hello".utf8), in: dir)
        let staging = AttachmentStaging()
        staging.add(files: [text])
        #expect(staging.items.isEmpty && staging.problem?.contains("notes.png is not a PNG") == true)
    }

    @Test func theSixthImageIsRefusedAndTheFirstFiveStay() throws {
        let dir = try folder()
        let png = try picture().png
        let files = try (0..<6).map { try file("s\($0).png", png, in: dir) }
        let staging = AttachmentStaging()
        staging.add(files: files)
        #expect(staging.items.count == GoalAttachments.maxCount)
        #expect(staging.problem == "\(GoalAttachments.Refusal.tooMany)")
    }

    @Test func aScreenshotOnTheClipboardBecomesAPNG() throws {
        let staging = AttachmentStaging()
        staging.add(imageData: try picture().tiff)
        let kept = try #require(staging.urls.first)
        #expect(kept.pathExtension == "png" && staging.problem == nil)
        #expect(try GoalAttachments.load(kept).ext == "png", "what was kept reads back as a PNG")
        staging.add(imageData: Data("nope".utf8))
        #expect(staging.items.count == 1 && staging.problem == "That is not an image.")
        staging.clear()
    }

    @Test func pastingTakesImagesAndLeavesTextForTheTextField() throws {
        let staging = AttachmentStaging()
        let board = NSPasteboard(name: NSPasteboard.Name("workbench-test-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("some words", forType: .string)
        #expect(staging.add(from: board) == false && staging.items.isEmpty, "plain text is not ours")

        board.clearContents()
        board.setData(try picture().tiff, forType: .tiff)
        #expect(staging.add(from: board) && staging.items.count == 1)

        let dir = try folder()
        board.clearContents()
        board.writeObjects([try file("a.png", try picture().png, in: dir) as NSURL])
        #expect(staging.add(from: board) && staging.items.count == 2)
        staging.clear()
    }

    @Test func aPasteIsForTheScreenshotsOnlyWhenTheClipboardHoldsAnImageAndNoText() throws {
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

    @Test func removingOneKeepsTheOthersInOrder() throws {
        let png = try picture().png
        let dir = try folder()
        let staging = AttachmentStaging()
        staging.add(files: [try file("a.png", png, in: dir), try file("b.png", png, in: dir), try file("c.png", png, in: dir)])
        let (first, second, third) = (staging.items[0], staging.items[1], staging.items[2])
        staging.remove(second)
        #expect(staging.items.map(\.id) == [first.id, third.id])
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
        staging.clear()
    }
}
