import Foundation

/// Other repositories a run may read (`read_also` in the project's config): the checkout next door that holds the backend, the shared
/// library. The turn is confined to its worktree on purpose; this opens exactly the listed folders, read-only, and nothing else.
public enum ReadAlso {
    public static let maxEntries = 5

    /// What the config's own syntax allows, before any folder is looked at.
    static func entryProblem(_ entry: String) -> String? {
        if entry.isEmpty { return "is empty" }
        if entry.count > 300 || entry.contains("\0") || entry.contains("\n") { return "is not a usable path" }
        return nil
    }

    /// Characters a path may have to be written into a permission rule: a rule's own punctuation and wildcards would change what it
    /// means, so a folder that has them is refused rather than escaped.
    static func pathProblem(_ path: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+@/")
        return path.unicodeScalars.allSatisfy(allowed.contains)
            ? nil : "its path has a space or a character a permission rule cannot hold safely"
    }

    /// The folders, as absolute resolved paths, or the first reason one cannot be used. A folder must exist, be a git checkout of its
    /// own (so a parent folder of everything is not opened by a stray `..`), and be neither the project nor inside it nor above it.
    public static func resolve(
        _ entries: [String], projectRoot: URL, home: String = NSHomeDirectory()
    ) -> Result<[URL], ReadAlsoProblem> {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        var found: [URL] = []
        for entry in entries {
            func problem(_ why: String) -> Result<[URL], ReadAlsoProblem> { .failure(ReadAlsoProblem(entry: entry, why: why)) }
            let expanded =
                entry == "~" ? home : entry.hasPrefix("~/") ? home + String(entry.dropFirst(1)) : entry
            let base = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
            let url = base.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return problem("\(url.path) is not a folder")
            }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
                return problem("\(url.path) is not the root of a git checkout")
            }
            let (a, b) = (url.path + "/", root.path + "/")
            if a == b || a.hasPrefix(b) || b.hasPrefix(a) { return problem("it is the project itself, inside it or above it") }
            if let why = pathProblem(url.path) { return problem(why) }
            if !found.contains(url) { found.append(url) }
        }
        return .success(found)
    }
}

public struct ReadAlsoProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public var entry: String
    public var why: String

    public var description: String { "read_also entry '\(entry)': \(why)" }
}
