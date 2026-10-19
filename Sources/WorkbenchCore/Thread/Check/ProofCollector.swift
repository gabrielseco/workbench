import CryptoKit
import Foundation

/// One file the verify step left in the proof directory, as `proof.added` recorded it.
public struct ProofFile: Sendable, Equatable {
    /// Relative to the proof directory.
    public var name: String
    /// Relative to the thread directory.
    public var path: String
    public var sha256: String
    public var bytes: Int
    /// The commit and tree the worktree held when the verify step ran (`ProofIdentity`), nil in an older log.
    public var commit: String?
    public var tree: String?
}

extension ProofFile {
    /// Whether the file recorded in the log is still there as recorded: a regular file (not a link), readable,
    /// and the size it had. The log is the inventory; this is the check before anything is shown as viewable.
    public func isAvailable(in threadDirectory: URL) -> Bool {
        let url = threadDirectory.appendingPathComponent(path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == bytes
        else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
}

/// Reads what a verifier left in a proof directory: the regular files, hashed and bounded, as `proof.added` records
/// them.
enum ProofCollector {
    /// Most files recorded per run. Past it the rest are counted, not listed.
    static let maxFiles = 200

    /// Most directory entries looked at, so a command that makes millions of files cannot hold the log.
    static let maxEntries = 5_000
    /// Largest file that is hashed, and the most bytes hashed in all. Past either, a file is counted, not listed.
    static let maxFileBytes = 64 << 20
    static let maxTotalBytes = 512 << 20
    /// Collecting is bounded in time too: it runs while the log is locked and the end of the run is still to be recorded.
    static let collectBudget: TimeInterval = 30

    /// The regular files under `proofDirectory`, sorted by name. Symlinks and anything else are left out, so
    /// the command cannot point the record at a file elsewhere on disk. Bounded in entries, bytes and time;
    /// whatever is not listed is counted in `omitted` (past the entry or time limit, at least that many).
    static func collect(
        proofDirectory: URL, threadDirectory: URL, maxEntries: Int = maxEntries, maxFileBytes: Int = maxFileBytes,
        maxTotalBytes: Int = maxTotalBytes, budget: TimeInterval = collectBudget
    ) -> (files: [ProofFile], omitted: Int) {
        let deadline = Date().addingTimeInterval(budget)
        guard
            let walker = FileManager.default.enumerator(
                at: proofDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [])
        else { return ([], 0) }
        var paths: [(url: URL, size: Int)] = []
        var omitted = 0
        var looked = 0
        for case let url as URL in walker {
            looked += 1
            if looked > maxEntries || Date() > deadline {
                // Stop walking: the rest is not looked at, so it cannot be counted. `omitted` is "at least".
                omitted += 1
                break
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isSymbolicLink != true, values.isRegularFile == true
            else { continue }
            paths.append((url, values.fileSize ?? 0))
        }
        paths.sort { $0.url.path < $1.url.path }
        var files: [ProofFile] = []
        var total = 0
        for (url, size) in paths {
            guard files.count < maxFiles, size <= maxFileBytes, total + size <= maxTotalBytes, Date() <= deadline,
                let digest = sha256(of: url, limit: maxFileBytes)
            else {
                omitted += 1
                continue
            }
            total += digest.bytes
            files.append(
                ProofFile(
                    name: relative(url, to: proofDirectory), path: relative(url, to: threadDirectory),
                    sha256: digest.hex, bytes: digest.bytes))
        }
        return (files, omitted)
    }

    /// The hash of a file read in chunks, so a large one is never held in memory; nil if it grows past `limit`.
    static func sha256(of url: URL, limit: Int) -> (hex: String, bytes: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            bytes += chunk.count
            if bytes > limit { return nil }
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }

    private static func relative(_ url: URL, to base: URL) -> String {
        let full = url.resolvingSymlinksInPath().path
        let root = base.resolvingSymlinksInPath().path
        return full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : url.lastPathComponent
    }
}
