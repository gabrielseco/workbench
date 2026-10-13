import Darwin
import Foundation

public struct FileChange: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case added, modified, deleted, renamed
    }

    public var path: String
    /// The previous path, for a rename.
    public var oldPath: String?
    public var status: Status
    /// `nil` for binary files, which have no line counts.
    public var additions: Int?
    public var deletions: Int?
    public var isBinary: Bool
    public var isUntracked: Bool
    public var isStaged = false
}

/// What a worktree holds compared to its base: the same set of files `git status` reports there, with
/// line counts. Patches are fetched per file with `patch(for:)` so a huge diff costs nothing until asked.
public struct DiffSummary: Sendable, Equatable {
    public var base: String
    public var files: [FileChange]
    /// `true` when there were more changed files than `DiffProvider.fileLimit`; `files` is cut.
    public var truncated: Bool
    public var totalFiles: Int
    public var indexFingerprint: String?

    public var additions: Int { files.reduce(0) { $0 + ($1.additions ?? 0) } }
    public var deletions: Int { files.reduce(0) { $0 + ($1.deletions ?? 0) } }
}

public enum FilePatch: Sendable, Equatable {
    case text(String)
    case binary
    /// The patch is larger than the cap; `bytes` is how large it is (the whole output, up to the runner's
    /// own cap).
    case tooLarge(bytes: Int)
}

public enum DiffError: Error, Equatable, Sendable, CustomStringConvertible {
    case worktreeNotFound(String)
    case gitFailed(command: String, status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .worktreeNotFound(let path): "no worktree at \(path)"
        case .gitFailed(let command, let status, let stderr):
            "git \(command) failed (exit \(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Reads a thread's changes out of its worktree. Compares the working tree to the commit the worktree was
/// cut from, so committed, staged, unstaged and untracked work all show, whatever state a stopped or
/// timed-out turn left behind.
public struct DiffProvider: Sendable {
    public static let fileLimit = 500
    public static let patchLimit = 256 << 10
    static let untrackedCountLimit = 1 << 20

    public let git: GitRunner

    public init(git: GitRunner) { self.git = git }

    /// `limit` caps the file list for display; a caller that must find one file passes `Int.max`.
    public func summary(
        worktree: URL, base: String, limit: Int = DiffProvider.fileLimit,
        includeIgnored: Bool = false, includeStaged: Bool = false
    ) async throws -> DiffSummary {
        try requireDirectory(worktree)

        let tracked = try await run(
            ["diff", "--numstat", "-z", "-M", "--no-ext-diff", "--no-color", base, "--"], in: worktree)
        let named = try await run(
            ["diff", "--name-status", "-z", "-M", "--no-ext-diff", "--no-color", base, "--"], in: worktree)
        let statuses = Self.parseNameStatus(named.stdout)
        var files = Self.parseNumstat(tracked.stdout).map { change -> FileChange in
            var change = change
            if change.oldPath == nil, let status = statuses[change.path] { change.status = status }
            return change
        }
        var indexFingerprint: String?
        if includeStaged {
            let staged = try await run(
                ["diff", "--cached", "--numstat", "-z", "-M", "--no-ext-diff", "--no-color", base, "--"], in: worktree)
            let stagedNames = try await run(
                ["diff", "--cached", "--name-status", "-z", "-M", "--no-ext-diff", "--no-color", base, "--"], in: worktree)
            let stagedStatuses = Self.parseNameStatus(stagedNames.stdout)
            files += Self.parseNumstat(staged.stdout).map { change -> FileChange in
                var change = change
                change.isStaged = true
                if change.oldPath == nil, let status = stagedStatuses[change.path] { change.status = status }
                return change
            }
            let snapshot = try await run(
                ["diff", "--cached", "--raw", "--no-abbrev", "-z", "--no-ext-diff", base, "--"], in: worktree)
            indexFingerprint = snapshot.stdout
        }

        let untracked = try await run(
            ["ls-files", "--others", "--exclude-standard", "-z"], in: worktree)
        for path in untracked.stdout.split(separator: "\0").map(String.init) {
            files.append(try untrackedChange(path, in: worktree))
        }
        // Discard removes ignored files too, so its confirmation must list them.
        if includeIgnored {
            let ignored = try await run(
                ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], in: worktree)
            for path in ignored.stdout.split(separator: "\0").map(String.init) {
                files.append(try untrackedChange(path, in: worktree))
            }
        }

        files.sort { $0.path < $1.path }
        let total = files.count
        if files.count > limit { files = Array(files.prefix(limit)) }
        return DiffSummary(
            base: base, files: files, truncated: total > files.count, totalFiles: total, indexFingerprint: indexFingerprint)
    }

    public func patch(for file: FileChange, worktree: URL, base: String) async throws -> FilePatch {
        try requireDirectory(worktree)
        if file.isBinary { return .binary }

        let result: GitResult
        if file.isUntracked {
            // `--no-index` exits 1 when the files differ, which is the normal case here.
            result = try await git.run(
                ["diff", "--no-index", "--no-ext-diff", "--no-color", "--", "/dev/null", file.path],
                in: worktree)
            guard result.status == 0 || result.status == 1 else {
                throw DiffError.gitFailed(command: "diff", status: result.status, stderr: result.stderr)
            }
        } else {
            var args = ["diff", "-M", "--no-ext-diff", "--no-color", base, "--"]
            if let old = file.oldPath { args.append(old) }
            args.append(file.path)
            result = try await run(args, in: worktree)
        }
        if result.stdout.utf8.count > Self.patchLimit {
            return .tooLarge(bytes: result.stdout.utf8.count)
        }
        return .text(result.stdout)
    }

    // MARK: Internals

    private func untrackedChange(_ path: String, in worktree: URL) throws -> FileChange {
        let url = worktree.appendingPathComponent(path)
        let unknown = FileChange(
            path: path, status: .added, additions: nil, deletions: nil, isBinary: true, isUntracked: true)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size <= Self.untrackedCountLimit
        else { return unknown }
        // A replaced path must not make inspection follow a symlink or block opening a FIFO.
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return unknown }
        defer { Darwin.close(fd) }
        guard fstat(fd, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size <= Self.untrackedCountLimit
        else { return unknown }
        var lines = 0
        var bytes = 0
        var last: UInt8 = 0x0A
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, Self.untrackedCountLimit + 1 - bytes))
            if count < 0 {
                if errno == EINTR { continue }
                return unknown
            }
            if count == 0 { break }
            bytes += count
            guard bytes <= Self.untrackedCountLimit else { return unknown }
            let chunk = buffer.prefix(count)
            if chunk.contains(0) { return unknown }
            lines += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            last = chunk[chunk.index(before: chunk.endIndex)]
        }
        if last != 0x0A { lines += 1 }
        return FileChange(
            path: path, status: .added, additions: lines, deletions: 0, isBinary: false, isUntracked: true)
    }

    /// `git diff --numstat -z -M`: `added<TAB>deleted<TAB>path<NUL>` for most files and
    /// `added<TAB>deleted<TAB><NUL>old<NUL>new<NUL>` for renames. Binary files show `-` for both counts.
    static func parseNumstat(_ output: String) -> [FileChange] {
        var changes: [FileChange] = []
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < fields.count {
            let head = fields[index]
            index += 1
            let parts = head.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let binary = parts[0] == "-" && parts[1] == "-"
            let added = Int(parts[0])
            let deleted = Int(parts[1])
            if parts[2].isEmpty {
                guard index + 1 < fields.count else { break }
                let old = fields[index], new = fields[index + 1]
                index += 2
                changes.append(
                    FileChange(
                        path: new, oldPath: old, status: .renamed, additions: added, deletions: deleted,
                        isBinary: binary, isUntracked: false))
            } else {
                let path = String(parts[2])
                changes.append(
                    FileChange(
                        path: path, status: .modified, additions: added, deletions: deleted, isBinary: binary,
                        isUntracked: false))
            }
        }
        return changes
    }

    /// `git diff --name-status -z -M`: `S<NUL>path<NUL>`, or `R<score><NUL>old<NUL>new<NUL>` and
    /// `C<score>...` which carry two paths. Returns the status by (new) path.
    static func parseNameStatus(_ output: String) -> [String: FileChange.Status] {
        var result: [String: FileChange.Status] = [:]
        let fields = output.split(separator: "\0").map(String.init)
        var index = 0
        while index < fields.count {
            let code = fields[index]
            index += 1
            let twoPaths = code.hasPrefix("R") || code.hasPrefix("C")
            guard index + (twoPaths ? 1 : 0) < fields.count else { break }
            let path = twoPaths ? fields[index + 1] : fields[index]
            index += twoPaths ? 2 : 1
            switch code.first {
            case "A": result[path] = .added
            case "D": result[path] = .deleted
            case "R": result[path] = .renamed
            default: result[path] = .modified
            }
        }
        return result
    }

    private func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw DiffError.worktreeNotFound(url.path) }
    }

    private func run(_ args: [String], in directory: URL) async throws -> GitResult {
        let result = try await git.run(args, in: directory)
        guard result.succeeded else {
            throw DiffError.gitFailed(
                command: args.first ?? "", status: result.status, stderr: result.stderr)
        }
        return result
    }
}
