import AppKit
import Foundation
import UniformTypeIdentifiers
import WorkbenchCore

/// The screenshots a person has added to a new goal, held as copies in a folder of their own until the draft has them. Core
/// checks each one (count, size, real image bytes); a rejected image says why and is not added. The copies are removed with
/// the sheet, so a file moved or deleted after it was added changes nothing.
@MainActor @Observable final class AttachmentStaging {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let thumbnail: NSImage?
    }

    private(set) var items: [Item] = []
    /// Why the last image was not added.
    private(set) var problem: String?
    @ObservationIgnored private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("workbench-attachments-\(UUID().uuidString)", isDirectory: true)

    var urls: [URL] { items.map(\.url) }

    /// Image files, from a drop, the open panel or a pasted file reference.
    func add(files: [URL]) {
        problem = nil
        for file in files where room() {
            do {
                let loaded = try GoalAttachments.load(file)
                keep(loaded)
            } catch { problem = "\(error)" }
        }
    }

    /// An image that has no file: what a screenshot taken to the clipboard puts there, as PNG or TIFF.
    func add(imageData data: Data) {
        problem = nil
        guard room() else { return }
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        guard let png else {
            problem = "That is not an image."
            return
        }
        guard png.count <= GoalAttachments.maxBytes else {
            problem = "That image is over \(GoalAttachments.maxBytes >> 20) MiB."
            return
        }
        keep(GoalAttachments.Loaded(data: png, ext: "png"))
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
    @discardableResult func add(from pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !files.isEmpty {
            add(files: files)
            return true
        }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return false }
        add(imageData: data)
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

    private func keep(_ loaded: GoalAttachments.Loaded) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).\(loaded.ext)")
            try loaded.data.write(to: url, options: .atomic)
            items.append(Item(url: url, thumbnail: NSImage(data: loaded.data)))
        } catch { problem = "The image could not be kept: \(error)" }
    }
}
