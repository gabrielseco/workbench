import Foundation

/// Scratch directories for tests: made under one root per test process, removed when the process exits.
///
/// Fixtures used to leave a `wb-*` directory per test behind (thousands after a few runs), and the fakes
/// beside them (`gh-*`, `codex-*`, `origin-*`) with them. Everything made through `Scratch.url` is gone after
/// the run, and `Scratch.sweepStale` removes what a run that was killed left.
enum Scratch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rootURL: URL?

    /// This process's root: `$TMPDIR/wb-scratch-<pid>-<uuid>`, created on first use and removed at exit.
    static var root: URL {
        lock.withLock {
            if let rootURL { return rootURL }
            sweepStale()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("wb-scratch-\(getpid())-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            rootURL = url
            atexit { Scratch.removeRoot() }
            return url
        }
    }

    /// A path for a new directory or file named `prefix-<uuid>`; nothing is created.
    static func url(_ prefix: String, ext: String? = nil) -> URL {
        let name = "\(prefix)-\(UUID().uuidString)" + (ext.map { ".\($0)" } ?? "")
        return root.appendingPathComponent(name)
    }

    /// A new empty directory.
    static func directory(_ prefix: String) throws -> URL {
        let url = url(prefix)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func removeRoot() {
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
    }

    /// Removes scratch roots of processes that no longer run (a killed run), and any `wb-*` directory older than
    /// a day left by the versions of the tests that made them directly.
    static func sweepStale(in tmp: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix("wb-") {
            let url = tmp.appendingPathComponent(name)
            if name.hasPrefix("wb-scratch-") {
                let parts = name.split(separator: "-")
                if parts.count > 2, let pid = Int32(parts[2]), kill(pid, 0) == 0 || errno == EPERM { continue }
            } else {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, now.timeIntervalSince(modified) > 86_400 else { continue }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
