import Foundation

/// The screenshots a person attaches to a goal request: checked here, shown to a drafter that can see images, and kept with the
/// thread in `attachments/` so the goal can point at them. Bounded, and only real image files: the bytes are sniffed, not the name.
public enum GoalAttachments {
    public static let maxCount = 5
    public static let maxBytes = 5 << 20
    /// Where a thread keeps them, relative to its folder, and what the goal's request links.
    public static let folder = "attachments"

    public struct Loaded: Sendable, Equatable {
        public var data: Data
        public var ext: String

        public init(data: Data, ext: String) { (self.data, self.ext) = (data, ext) }
    }

    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case tooMany
        case notAnImage(String)
        case tooLarge(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .tooMany: "at most \(GoalAttachments.maxCount) images can be attached."
            case .notAnImage(let name): "\(name) is not a PNG, JPEG, GIF or WebP image."
            case .tooLarge(let name): "\(name) is over \(GoalAttachments.maxBytes >> 20) MiB."
            case .unreadable(let name): "\(name) could not be read as a regular file."
            }
        }
    }

    /// Reads each file once, refusing a link, a folder, an oversized file or anything whose first bytes are not an image's.
    public static func load(_ urls: [URL]) throws -> [Loaded] {
        guard urls.count <= maxCount else { throw Refusal.tooMany }
        return try urls.map(load)
    }

    public static func load(_ url: URL) throws -> Loaded {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true, let size = values?.fileSize else {
            throw Refusal.unreadable(name)
        }
        guard size <= maxBytes else { throw Refusal.tooLarge(name) }
        guard let data = try? Data(contentsOf: url), data.count <= maxBytes else { throw Refusal.unreadable(name) }
        guard let ext = kind(of: data) else { throw Refusal.notAnImage(name) }
        return Loaded(data: data, ext: ext)
    }

    /// The file extension an image's first bytes say it has; nil when they are not a supported image.
    static func kind(of data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) { return "gif" }
        if head.count == 12, head.starts(with: Array("RIFF".utf8)), Array(head[8...]) == Array("WEBP".utf8) { return "webp" }
        return nil
    }

    /// `1.png`, `2.jpg`, …: numbered by order, never by what the file was called.
    static func names(_ items: [Loaded]) -> [String] {
        items.enumerated().map { "\($0.offset + 1).\($0.element.ext)" }
    }

    /// What is added to the goal's request so a reader (and an editor's preview) finds the images.
    static func markdown(_ names: [String]) -> String {
        "Screenshots from the request:\n\n"
            + names.enumerated().map { "![screenshot \($0.offset + 1)](\(folder)/\($0.element))" }.joined(separator: "\n")
    }

    /// Writes the images into `directory`, creating it.
    static func write(_ items: [Loaded], into directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try zip(names(items), items).map { name, item in
            let url = directory.appendingPathComponent(name)
            try item.data.write(to: url, options: .atomic)
            return url
        }
    }
}
