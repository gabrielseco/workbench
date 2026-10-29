import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WorkbenchCore

/// The screenshots a person has added to a new goal, held as copies in a folder of their own until the draft has them. Core
/// checks each one (count, size, pixels, real image bytes); a rejected image says why and is not added. The copies are removed
/// with the sheet, so a file moved or deleted after it was added changes nothing. Reading, converting and thumbnailing happen off
/// the main actor, and nothing is decoded before its size is known to be within bounds.
@MainActor @Observable final class AttachmentStaging {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let thumbnail: NSImage?
    }

    /// The most clipboard bytes that are looked at: a screenshot's TIFF is far bigger than the PNG it becomes.
    nonisolated static let maxRawBytes = 64 << 20
    nonisolated static let thumbnailPixels = 104

    private(set) var items: [Item] = []
    /// Why the last image was not added.
    private(set) var problem: String?
    @ObservationIgnored private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("workbench-attachments-\(UUID().uuidString)", isDirectory: true)

    var urls: [URL] { items.map(\.url) }

    /// Image files, from a drop, the open panel or a pasted file reference.
    func add(files: [URL]) async {
        problem = nil
        for file in files {
            guard room() else { return }
            let folder = directory
            await keep(Task.detached { try Self.stage(file: file, in: folder) }.result)
        }
    }

    /// An image that has no file: what a screenshot taken to the clipboard puts there, as PNG or TIFF.
    func add(imageData data: Data, rawLimit: Int = maxRawBytes) async {
        problem = nil
        guard room() else { return }
        let folder = directory
        await keep(Task.detached { try Self.stage(imageData: data, rawLimit: rawLimit, in: folder) }.result)
    }

    /// Whether a paste of this clipboard is for the screenshots: it carries an image (a file or picture data) and no text. A
    /// clipboard with text goes to the text field as always, whatever else it carries.
    static func wantsImages(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.string) { return false }
        if types.contains(.png) || types.contains(.tiff) { return true }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: options)
    }

    /// What a paste brings: image files first, else an image on the clipboard. False when there was none, so text still pastes.
    @discardableResult func add(from pasteboard: NSPasteboard) async -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !files.isEmpty {
            await add(files: files)
            return true
        }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return false }
        await add(imageData: data)
        return true
    }

    func remove(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
        problem = nil
    }

    /// Removes every copy: after the draft has been made, or the sheet is dismissed.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
        items = []
        problem = nil
    }

    private func room() -> Bool {
        guard items.count < GoalAttachments.maxCount else {
            problem = "\(GoalAttachments.Refusal.tooMany)"
            return false
        }
        return true
    }

    /// Adds a staged image, unless the sheet filled up or was cleared while it was being prepared.
    private func keep(_ result: Result<Staged, Error>) {
        switch result {
        case .success(let staged):
            guard room() else {
                try? FileManager.default.removeItem(at: staged.url)
                return
            }
            items.append(Item(url: staged.url, thumbnail: staged.thumbnail.flatMap { NSImage(data: $0) }))
        case .failure(let error):
            problem = "\(error)"
        }
    }

    // MARK: Off the main actor

    private struct Staged: Sendable {
        var url: URL
        var thumbnail: Data?
    }

    private struct Problem: Error, CustomStringConvertible {
        var description: String
    }

    nonisolated private static func stage(file: URL, in folder: URL) throws -> Staged {
        let loaded = try GoalAttachments.load(file)
        return try keep(loaded, in: folder)
    }

    nonisolated private static func stage(imageData data: Data, rawLimit: Int, in folder: URL) throws -> Staged {
        guard data.count <= rawLimit else { throw Problem(description: "That image is too large to read.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int
        else { throw Problem(description: "That is not an image.") }
        guard width * height <= GoalAttachments.maxPixels else {
            throw Problem(description: "That image has more than \(GoalAttachments.maxPixels / 1_000_000) million pixels.")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let png = pngData(image) else {
            throw Problem(description: "That is not an image.")
        }
        guard png.count <= GoalAttachments.maxBytes else {
            throw Problem(description: "That image is over \(GoalAttachments.maxBytes >> 20) MiB.")
        }
        // The bytes are checked like any attached file's: what was written is what the drafter gets.
        let scratch = folder.appendingPathComponent(".incoming-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: scratch, options: .atomic)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try keep(try GoalAttachments.load(scratch), in: folder)
    }

    nonisolated private static func keep(_ loaded: GoalAttachments.Loaded, in folder: URL) throws -> Staged {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(UUID().uuidString).\(loaded.ext)")
        try loaded.data.write(to: url, options: .atomic)
        return Staged(url: url, thumbnail: thumbnail(of: loaded.data))
    }

    nonisolated private static func thumbnail(of data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).flatMap(pngData)
    }

    nonisolated private static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        let type = UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
