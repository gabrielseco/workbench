import Foundation
import WorkbenchCore

/// The pull requests GitHub confirmed merged, kept on disk so the rail is right on its first paint instead of amber until `gh` has
/// answered for every thread. A merge cannot be undone, so it is the one outcome kept; the log never says it, so this is the only copy.
enum MergedPullRequests {
    private struct Entry: Codable { var number: Int, head: String }

    /// More than a person has threads; the file is bounded like everything else.
    static let maxEntries = 2000
    static let maxBytes = 1_000_000

    static func url(_ project: Project) -> URL { project.workbenchDirectory.appendingPathComponent("merged-pull-requests.json") }

    private static func read(_ project: Project) -> [String: Entry] {
        // At most the limit plus one byte is read, so a file that grew by accident is refused without being held.
        guard let handle = try? FileHandle(forReadingFrom: url(project)) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Thread id to the merged status recorded for it. The id is only ever a key compared with the listed ones, never a path.
    static func load(_ project: Project) -> [String: PRStatus] {
        read(project).reduce(into: [:]) { found, pair in
            guard pair.value.number > 0 else { return }
            found[pair.key] = PRStatus(number: pair.value.number, state: .merged, head: pair.value.head, checks: nil)
        }
    }

    /// Remembers `status` for `thread` when it is merged and not already known; nothing else is kept.
    static func remember(_ status: PRStatus?, thread: String, in project: Project) {
        guard let status, status.state == .merged else { return }
        var entries = read(project)
        guard entries[thread]?.number != status.number, entries.count < maxEntries else { return }
        entries[thread] = Entry(number: status.number, head: status.head)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: project.workbenchDirectory, withIntermediateDirectories: true)
        try? data.write(to: url(project), options: .atomic)
    }
}
