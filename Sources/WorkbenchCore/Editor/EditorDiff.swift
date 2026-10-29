import Foundation

/// A changed file's diff in the editor's own diff view: the version at the thread's base beside the one in the worktree.
/// Editors diff two files, not two folders, so a whole review is one view per file.
public enum EditorDiff {
    /// The known editors that take `--diff <old> <new>`.
    public static let supported: Set<String> = ["code", "cursor", "windsurf", "zed"]
    /// Views opened by one "open the diff" and the largest base version copied out for one of them.
    public static let fileLimit = 10
    public static let sizeLimit = 2 << 20

    public struct Opened: Sendable, Equatable {
        public var opened: [String] = []
        /// Binary or too large for a text diff.
        public var skipped: [String] = []
        /// Changed files past `fileLimit` that were not tried.
        public var more = 0
    }

    /// `<editor> --diff <old> <new>`, from the editor's launcher on PATH: the macOS `open -a` fallback cannot pass arguments to an
    /// app that is already running.
    public static func command(for value: String, old: URL, new: URL, searchPath: String?) throws -> EditorCommand {
        guard supported.contains(value) else { throw EditorError.noDiffMode(editor: value) }
        let absolute = (searchPath ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.joined(separator: ":")
        guard let launcher = ExecutableResolver.resolve(value, searchPath: absolute) else {
            throw EditorError.notFound(editor: value, tried: ["'\(value)' on PATH (a diff needs the command, not the app)"])
        }
        return EditorCommand(executable: launcher.path, arguments: ["--diff", old.path, new.path])
    }

    /// Opens each of `files` (all of them when `only` is nil, else the one at that path), at most `fileLimit`. The base versions
    /// are written read-only under `scratch`, which is emptied first, so a later call replaces them.
    public static func open(
        files: [FileChange], only: String?, base: String, worktree: URL, scratch: URL, git: GitRunner, editor: String,
        environment: [String: String]
    ) async throws -> Opened {
        // Before anything is written, so an editor with no diff view costs nothing.
        _ = try command(for: editor, old: scratch, new: scratch, searchPath: environment["PATH"])
        guard base.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil else {
            throw EditorError.launchFailed(editor: editor, reason: "the thread's base is not a commit id")
        }
        var wanted = files.filter { only == nil || $0.path == only }
        var result = Opened()
        if only == nil, wanted.count > fileLimit {
            result.more = wanted.count - fileLimit
            wanted = Array(wanted.prefix(fileLimit))
        }
        try? FileManager.default.removeItem(at: scratch)
        for (slot, file) in wanted.enumerated() {
            let sides = file.isBinary ? nil : try await copies(
                of: file, slot: slot, base: base, worktree: worktree, scratch: scratch, git: git)
            guard let (old, new) = sides else {
                result.skipped.append(file.path)
                continue
            }
            let run = try command(for: editor, old: old, new: new, searchPath: environment["PATH"])
            try await EditorLauncher.launch(run, editor: editor, in: worktree, environment: Editor.environment(from: environment))
            result.opened.append(file.path)
        }
        return result
    }

    /// The old side (empty for an added file) and the new side (the worktree's file, empty for a deleted one); nil when the file
    /// is not a plain file of text size, or its path is not one inside the worktree.
    private static func copies(
        of file: FileChange, slot: Int, base: String, worktree: URL, scratch: URL, git: GitRunner
    ) async throws -> (old: URL, new: URL)? {
        guard isInside(file.path), isInside(file.oldPath ?? file.path) else { return nil }
        let folder = scratch.appendingPathComponent("\(slot)", isDirectory: true)
        let name = URL(fileURLWithPath: file.path).lastPathComponent
        let old = folder.appendingPathComponent("base", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = Data()
        if file.status != .added {
            let shown = try await git.run(["show", "\(base):\(file.oldPath ?? file.path)"], in: worktree)
            guard shown.succeeded, !shown.outputTruncated, shown.stdoutBytes.count <= sizeLimit else { return nil }
            bytes = shown.stdoutBytes
        }
        // The bytes as git has them: a file in another encoding must not show changes nobody made.
        try bytes.write(to: old, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: old.path)

        let live = worktree.appendingPathComponent(file.path)
        // A folder the agent replaced with a link would let `lstat` below reach a file outside the worktree.
        let home = worktree.resolvingSymlinksInPath().path
        let parent = live.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == home || parent.hasPrefix(home + "/") else { return nil }
        var metadata = stat()
        if lstat(live.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= sizeLimit else { return nil }
            return (old, live)
        }
        // Deleted: an empty file stands for it.
        let gone = folder.appendingPathComponent("deleted", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: gone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: gone)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: gone.path)
        return (old, gone)
    }

    /// A relative path of plain parts: nothing that climbs out of the worktree.
    static func isInside(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && !parts.contains { [".", "..", ""].contains($0) }
    }
}
