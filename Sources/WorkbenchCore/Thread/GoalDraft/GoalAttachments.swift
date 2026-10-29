import Foundation

/// The screenshots a person attaches to a goal request: checked here, shown to a drafter that can see images, and kept with the
/// thread in `attachments/` so the goal can point at them. Bounded, and only real image files: the bytes are sniffed, not the name.
public enum GoalAttachments {
    public static let maxCount = 5
    public static let maxBytes = 5 << 20
    /// The most pixels an image may have (8000 x 5000): a small file can still decode to a huge one.
    public static let maxPixels = 40_000_000
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
        case tooManyPixels(String)
        case tooLarge(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .tooMany: "at most \(GoalAttachments.maxCount) images can be attached."
            case .notAnImage(let name): "\(name) is not a PNG, JPEG, GIF or WebP image."
            case .tooManyPixels(let name): "\(name) has more than \(GoalAttachments.maxPixels / 1_000_000) million pixels."
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
        guard let shape = inspect(data) else { throw Refusal.notAnImage(name) }
        if let width = shape.width, let height = shape.height, width * height > maxPixels { throw Refusal.tooManyPixels(name) }
        return Loaded(data: data, ext: shape.ext)
    }

    /// What the bytes of a complete image say it is: its type and, where the format states them up front, its size in pixels.
    /// Not a decoder: it checks the signature, the header's own fields and the format's ending, so a bare signature, a cut file
    /// or text with an image's name is refused here, before a paid agent is asked to look at it.
    struct Shape: Equatable {
        var ext: String
        var width: Int?
        var height: Int?
    }

    static func inspect(_ data: Data) -> Shape? {
        let bytes = [UInt8](data)
        return png(bytes) ?? jpeg(bytes) ?? gif(bytes) ?? webp(bytes)
    }

    /// The type alone, for what only needs to tell the formats apart.
    static func kind(of data: Data) -> String? { inspect(data)?.ext }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func png(_ b: [UInt8]) -> Shape? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let iend: [UInt8] = [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        guard b.count >= 8 + 25 + 12, b.starts(with: signature), be32(b, 8) == 13, Array(b[12..<16]) == Array("IHDR".utf8),
            Array(b.suffix(12)) == iend
        else { return nil }
        let (width, height) = (be32(b, 16), be32(b, 20))
        guard width > 0, height > 0 else { return nil }
        return Shape(ext: "png", width: width, height: height)
    }

    private static func jpeg(_ b: [UInt8]) -> Shape? {
        guard b.count >= 4, b.starts(with: [0xFF, 0xD8, 0xFF]) else { return nil }
        var end = b.count
        while end > 0, b[end - 1] == 0 { end -= 1 }
        guard end >= 2, b[end - 2] == 0xFF, b[end - 1] == 0xD9 else { return nil }
        var i = 2
        while i + 4 <= end {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF {
                i += 1
                continue
            }
            if marker == 0xDA { return nil }  // the scan began and no frame header came before it
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= end else { return nil }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard length >= 8 else { return nil }
                let height = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let width = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return width > 0 && height > 0 ? Shape(ext: "jpg", width: width, height: height) : nil
            }
            i += 2 + length
        }
        return nil
    }

    private static func gif(_ b: [UInt8]) -> Shape? {
        guard b.count >= 14, b.starts(with: Array("GIF87a".utf8)) || b.starts(with: Array("GIF89a".utf8)), b.last == 0x3B
        else { return nil }
        let width = Int(b[6]) | Int(b[7]) << 8
        let height = Int(b[8]) | Int(b[9]) << 8
        return width > 0 && height > 0 ? Shape(ext: "gif", width: width, height: height) : nil
    }

    private static func webp(_ b: [UInt8]) -> Shape? {
        guard b.count >= 20, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) else { return nil }
        let size = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        let chunk = String(decoding: b[12..<16], as: UTF8.self)
        guard b.count == size + 8 || b.count == size + 9, ["VP8 ", "VP8L", "VP8X"].contains(chunk) else { return nil }
        return Shape(ext: "webp", width: nil, height: nil)
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
