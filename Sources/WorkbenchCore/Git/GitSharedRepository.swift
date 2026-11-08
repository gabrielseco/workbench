import Foundation

/// What several threads of a project share: one `.git`. Git takes its own lock files for refs and the index, and a second command
/// that meets one fails with "File exists" instead of waiting, so Workbench lets one command at a time change it.
enum GitSharedRepository {
    /// Another command of this project held the shared git lock for the whole wait.
    struct Busy: Error, CustomStringConvertible {
        var arguments: [String]
        var seconds: Int
        var description: String {
            "`git \(arguments.prefix(3).joined(separator: " "))` waited \(seconds) s for another git command of this project to "
                + "finish, and gave up; nothing was changed by it. Try again."
        }
    }

    /// A short pause before the one retry of a command that met a lock file.
    static let retryDelayNanoseconds: UInt64 = 500_000_000

    /// True for a command that changes refs, objects or the worktree list of the shared repository: it is run alone.
    static func changesIt(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == "-C" || word == "-c" { index += 2 } else if word.hasPrefix("-") { index += 1 } else { break }
        }
        guard index < arguments.count else { return false }
        let command = arguments[index]
        let rest = arguments[(index + 1)...]
        switch command {
        case "fetch", "gc", "push", "update-ref", "pack-refs", "repack", "prune": return true
        case "worktree": return rest.first.map { ["add", "remove", "prune", "move", "repair"].contains($0) } ?? false
        case "branch":
            let editing: Set<String> = ["-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy"]
            return rest.contains { editing.contains($0) }
        default: return false
        }
    }

    /// Git's message when another command holds a lock file: `Unable to create '….lock': File exists` or `cannot lock ref`.
    static func isLockFileError(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return (text.contains(".lock") && text.contains("file exists")) || text.contains("cannot lock ref")
    }

    /// The `.git` directory all of a repository's worktrees share, read from the files, with no git process. Nil when `directory`
    /// is not in a checkout.
    static func commonDirectory(from directory: URL) -> URL? {
        var folder = directory.standardizedFileURL
        let manager = FileManager.default
        for _ in 0..<64 {
            let dotGit = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dotGit }
                // A linked worktree: `.git` is a file, `gitdir: <repo>/.git/worktrees/<name>`, and that has `commondir`.
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                    let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:")
                else { return nil }
                let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL
                // A checkout made with `--separate-git-dir` points at its repository directly, which has no `commondir`.
                guard let relative = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) else {
                    return gitDir
                }
                let common = URL(
                    fileURLWithPath: relative.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir)
                return common.standardizedFileURL
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            folder = parent
        }
        return nil
    }

    /// An exclusive lock on the common git directory itself (no file is left). The wait polls without blocking a thread, and is
    /// bounded: the longest a holder runs is its own command timeout.
    static func acquire(_ directory: URL, arguments: [String], wait: TimeInterval) async throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        // A directory that cannot be opened has nothing to lock: run unserialized rather than fail the command.
        guard descriptor >= 0 else { return -1 }
        let deadline = Date().addingTimeInterval(wait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(descriptor)
                throw Busy(arguments: arguments, seconds: Int(wait))
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return descriptor
    }
}
