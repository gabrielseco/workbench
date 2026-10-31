import Foundation

public enum TaskFileError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case outsideProject(String)
    case tooLarge(String, bytes: Int, limit: Int)
    case tooMany(String, limit: Int)
    case unreadable(String)

    public var description: String {
        switch self {
        case .notFound(let path): "'\(path)' does not exist in the project"
        case .outsideProject(let path): "'\(path)' leaves the project (a link or a path that points elsewhere)"
        case .tooLarge(let path, let bytes, let limit): "'\(path)' is \(bytes) bytes; the limit is \(limit)"
        case .tooMany(let path, let limit): "'\(path)' holds more than \(limit) files"
        case .unreadable(let path): "'\(path)' cannot be read"
        }
    }
}

/// Reads the files a task points at. Every path is resolved against the project root and must still be inside it
/// after links are followed: a task file is data from a repository and must not reach the rest of the disk.
struct TaskFiles {
    static let maxScriptBytes = 256 << 10
    static let maxInputBytes = 1 << 20
    static let maxInputFiles = 200

    let root: URL

    init(project: Project) { root = project.root.resolvingSymlinksInPath() }

    func resolve(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else { throw TaskFileError.outsideProject(relative) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw TaskFileError.notFound(relative) }
        return url
    }

    /// A single file, read whole, up to `limit` bytes.
    func read(_ relative: String, limit: Int) throws -> Data {
        let url = try resolve(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw TaskFileError.unreadable(relative)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limit else { throw TaskFileError.tooLarge(relative, bytes: size, limit: limit) }
        guard let data = try? Data(contentsOf: url) else { throw TaskFileError.unreadable(relative) }
        return data
    }
}

/// One input file, as it goes into the prompt.
public struct TaskInput: Sendable, Equatable {
    /// Path from the project root.
    public var path: String
    public var text: String
}

extension TaskFiles {
    /// The input files of a task: each path is a file or a directory (read recursively, hidden files skipped). The engine
    /// does not parse them: it hands their text to the agent, fenced as untrusted data. Bounded in files and bytes.
    func inputs(_ paths: [String]) throws -> [TaskInput] {
        var result: [TaskInput] = []
        var total = 0
        for relative in paths {
            let url = try resolve(relative)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            var files: [URL] = [url]
            if isDirectory.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey]
                let walker = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                files = []
                while let next = walker?.nextObject() as? URL {
                    guard (try? next.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
                    files.append(next)
                    if files.count > Self.maxInputFiles { throw TaskFileError.tooMany(relative, limit: Self.maxInputFiles) }
                }
                files.sort { $0.path < $1.path }
            }
            for file in files {
                let resolved = file.resolvingSymlinksInPath()
                let rel = String(resolved.path.dropFirst(root.path.count + 1))
                guard resolved.path.hasPrefix(root.path + "/") else { throw TaskFileError.outsideProject(relative) }
                let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += size
                guard total <= Self.maxInputBytes else {
                    throw TaskFileError.tooLarge(relative, bytes: total, limit: Self.maxInputBytes)
                }
                guard let data = try? Data(contentsOf: resolved) else { throw TaskFileError.unreadable(rel) }
                result.append(TaskInput(path: rel, text: String(decoding: data, as: UTF8.self)))
            }
        }
        return result
    }
}
