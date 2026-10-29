import Foundation

/// A thread's changes as uncommitted work in a folder of their own: a copy of the repository at the thread's base with each changed
/// file put as the worktree has it, so the editor's source control view lists them all and a click opens one diff. It never
/// touches the thread's worktree, and what is edited there does not go back to the thread.
public enum ReviewWorkspace {
    /// The folder's name in the thread's directory; a rebuild replaces it.
    public static let folderName = "review-workspace"
    /// The largest changed file copied in; a bigger one is left out and named.
    public static let sizeLimit = 8 << 20

    public struct Built: Sendable, Equatable {
        public var path: URL
        public var changed = 0
        /// Not copied: not a plain file, or too large. The workspace shows them as unchanged.
        public var skipped: [String] = []
    }

    /// Builds the workspace at `destination` (which is emptied first, and must be named `review-workspace`).
    public static func build(
        files: [FileChange], base: String, worktree: URL, repository: URL, destination: URL, git: GitRunner
    ) async throws -> Built {
        guard destination.lastPathComponent == folderName else {
            throw EditorError.launchFailed(editor: "", reason: "the review workspace is not in a \(folderName) folder")
        }
        guard base.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil else {
            throw EditorError.launchFailed(editor: "", reason: "the thread's base is not a commit id")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A shared clone: it reads the repository's objects, registers nothing in it, and is removed like any folder.
        try await run(
            git, ["clone", "--quiet", "--shared", "--no-checkout", "--no-hardlinks", "--", repository.path, destination.path],
            in: repository)
        // The clone has no remote to push to.
        try await run(git, ["remote", "remove", "origin"], in: destination)
        try await run(git, ["checkout", "--quiet", "--detach", base], in: destination)

        var built = Built(path: destination)
        var seen = Set<String>()
        let listed = files.filter { !$0.isIgnored && seen.insert($0.path).inserted }
        var usable: [FileChange] = []
        for file in listed {
            guard EditorDiff.isInside(file.path), EditorDiff.isInside(file.oldPath ?? file.path) else {
                built.skipped.append(file.path)
                continue
            }
            usable.append(file)
        }
        // Every path the thread no longer has goes first, then every final version is copied: whatever the order of the list, a
        // new file at a renamed file's old path is not removed after it was written. A rename whose new version cannot be copied
        // is left as the base has it, not shown as a deletion.
        var copies: [FileChange] = []
        for file in usable {
            if file.status == .deleted {
                remove(file.path, in: destination)
                built.changed += 1
            } else if copyable(file.path, from: worktree) {
                if file.status == .renamed { remove(file.oldPath ?? file.path, in: destination) }
                copies.append(file)
            } else {
                built.skipped.append(file.path)
            }
        }
        var added: [String] = []
        for file in copies {
            if try copy(file.path, from: worktree, to: destination) {
                built.changed += 1
                if file.status == .added || file.status == .renamed { added.append(file.path) }
            } else {
                built.skipped.append(file.path)
            }
        }
        try await track(ignored: added, in: destination, git: git)
        return built
    }

    /// The thread's changes, from its worktree, in the thread's `review-workspace` folder. Throws `noWorktree` when there is no diff.
    public static func prepare(project: Project, threadID: String, git: GitRunner) async throws -> Built {
        let worktree = try Editor.worktree(project: project, threadID: threadID)
        guard let changes = await ReviewLoader(project: project, git: git).changedFiles(id: threadID) else {
            throw EditorError.noWorktree(id: threadID, path: worktree.path)
        }
        return try await build(
            files: changes.files, base: changes.base, worktree: worktree, repository: project.root,
            destination: project.threadDirectory(threadID).appendingPathComponent(folderName, isDirectory: true), git: git)
    }

    private static func chunks(of paths: [String], size: Int = 100) -> [[String]] {
        stride(from: 0, to: paths.count, by: size).map { Array(paths[$0..<min($0 + size, paths.count)]) }
    }

    private static func remove(_ path: String, in destination: URL) {
        let gone = destination.appendingPathComponent(path)
        if contained(gone.deletingLastPathComponent(), in: destination) { try? FileManager.default.removeItem(at: gone) }
    }

    /// Whether `copy` would take the file from the worktree: a plain file of a size worth copying, not reached through a link.
    private static func copyable(_ path: String, from worktree: URL) -> Bool {
        let source = worktree.appendingPathComponent(path)
        guard contained(source.deletingLastPathComponent(), in: worktree) else { return false }
        var metadata = stat()
        return lstat(source.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_size <= sizeLimit
    }

    /// A file the repository ignores that the thread added (it was forced into the thread's branch) would be hidden from
    /// source control; marking it as intended to be added shows it as a new file without staging its contents.
    private static func track(ignored candidates: [String], in destination: URL, git: GitRunner) async throws {
        var ignored: [String] = []
        for chunk in chunks(of: candidates) {
            // Exit 1 is "none of these is ignored"; the paths come back one per line, quoted when they hold odd characters, so
            // `-z` is not used (git allows it only with --stdin) and a quoted answer simply fails to match and is not tracked.
            let found = try await git.run(["check-ignore", "--"] + chunk, in: destination)
            ignored += found.stdout.split(separator: "\n").map(String.init).filter { chunk.contains($0) }
        }
        for chunk in chunks(of: ignored) {
            try await run(git, ["add", "--force", "--intent-to-add", "--"] + chunk, in: destination)
        }
    }

    /// Copies one file when it is a plain file of a size worth copying, and both folders it passes through are really inside
    /// their roots (a link the agent or the repository holds must not lead a write or a read elsewhere).
    private static func copy(_ path: String, from worktree: URL, to destination: URL) throws -> Bool {
        let source = worktree.appendingPathComponent(path)
        let target = destination.appendingPathComponent(path)
        guard contained(source.deletingLastPathComponent(), in: worktree) else { return false }
        var metadata = stat()
        guard lstat(source.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= sizeLimit else {
            return false
        }
        // The folders are made only once the nearest one that exists is known to be inside: making them first would follow a link.
        var existing = target.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: existing.path), existing.path.count > destination.path.count {
            existing = existing.deletingLastPathComponent()
        }
        guard contained(existing, in: destination) else { return false }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        return true
    }

    private static func contained(_ folder: URL, in root: URL) -> Bool {
        let home = root.resolvingSymlinksInPath().path
        let resolved = folder.resolvingSymlinksInPath().path
        return resolved == home || resolved.hasPrefix(home + "/")
    }

    private static func run(_ git: GitRunner, _ arguments: [String], in directory: URL) async throws {
        let result = try await git.run(arguments, in: directory)
        guard result.succeeded else {
            let why = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EditorError.launchFailed(editor: "", reason: "git \(arguments[0]) failed: \(why)")
        }
    }
}
