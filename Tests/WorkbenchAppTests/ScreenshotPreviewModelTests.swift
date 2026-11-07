import CoreGraphics
import Foundation
import Testing

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

    @Test func pagingDropsThePictureAndTheZoomOfTheOneBefore() {
        let model = ScreenshotPreviewModel.proof(shots(2), at: 0)
        model.actualSize = true
        model.go(1)
        #expect(model.decoded == nil && !model.actualSize, "the next one starts fitted, and waits for its own decode")
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

    @Test func theAreaIsTheImagesOwnSizeWithinTheRoomAndNoSmallerThanTheLeast() throws {
        let model = ScreenshotPreviewModel.proof(shots(1), at: 0)
        let room = ScreenshotPreviewModel.room(screen: CGSize(width: 1440, height: 900))
        #expect(model.area(scale: 2, room: room) == ScreenshotPreviewModel.smallest, "before it is decoded")
        #expect(room.width < 1440 * 0.9 && room.height < 900 * 0.85, "the modal's own padding and header come out of the room")
    }

    /// A 1 × 1 PNG.
    private static let pixel =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
}
