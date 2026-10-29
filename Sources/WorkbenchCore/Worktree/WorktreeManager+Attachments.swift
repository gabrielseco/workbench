import Foundation

/// The goal's screenshots inside a worktree, beside the goal copy.
extension WorktreeManager {
    /// Where the goal's screenshots are shown inside a worktree: beside the goal copy, so the goal's own relative links
    /// (`attachments/1.png`) resolve there. Kept out of git the same way, and inside the worktree, where a coding turn may read.
    public static let attachmentCopyFolder = ".workbench/goal-copy/attachments"

    /// Puts read-only copies of the thread's screenshots in the worktree, replacing the ones an earlier turn left, and returns
    /// their names in order: empty when nothing was written, so a prompt never names a file that is not there.
    ///
    /// Same care as the goal copy: it writes only into plain folders of its own, never over a file git tracks, and only where git
    /// would ignore the result, file by file (a project's rules may un-ignore one name); a copy git would see is removed, not
    /// written. It touches only names `GoalAttachments` writes: `<n>.<png|jpg|gif|webp>`, n a canonical positive number.
    public func writeAttachmentCopies(_ sources: [URL], for threadID: String) async -> [String] {
        guard SafeNames.isThreadID(threadID), exists(threadID) else { return [] }
        let worktree = path(for: threadID)
        let folder = worktree.appendingPathComponent(Self.attachmentCopyFolder, isDirectory: true)
        var dir = worktree
        for part in Self.attachmentCopyFolder.split(separator: "/") {
            dir = dir.appendingPathComponent(String(part), isDirectory: true)
            if let type = Self.type(of: dir), type != .typeDirectory { return [] }
        }
        let tracked = try? await git.run(["ls-files", "--", Self.attachmentCopyFolder], in: worktree)
        if tracked?.succeeded != true || !(tracked?.stdout.isEmpty ?? false) { return [] }
        // Only the sources git would ignore are written; for the rest an earlier copy of ours is removed like a stale one.
        var usable: [URL] = []
        for source in sources where GoalAttachments.number(inStoredName: source.lastPathComponent) != nil {
            let relative = Self.attachmentCopyFolder + "/" + source.lastPathComponent
            if (try? await git.run(["check-ignore", "-q", "--", relative], in: worktree))?.succeeded == true {
                usable.append(source)
            }
        }
        let wanted = usable.map(\.lastPathComponent)
        for name in Self.ownedNames(in: folder) where !wanted.contains(name) { Self.removeOwned(name, in: folder) }
        guard !usable.isEmpty else { return [] }
        var written: [String] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for source in usable {
                let name = source.lastPathComponent
                let target = folder.appendingPathComponent(name)
                // Replaced by a rename, never changed in place: a name that was made a hard link to another file is cut
                // loose from it, and that file's own permissions and content are not touched.
                if let type = Self.type(of: target), type != .typeRegular { return written }
                try Data(contentsOf: source).write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: target.path)
                written.append(name)
            }
        } catch {
            return written
        }
        return written
    }

    /// The names in `folder` this feature writes: a number and an image extension, as plain files.
    private static func ownedNames(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
            GoalAttachments.number(inStoredName: name) != nil
                && type(of: folder.appendingPathComponent(name)) == .typeRegular
        }
    }

    private static func removeOwned(_ name: String, in folder: URL) {
        // Unlinking needs the folder's write permission, not the file's: no chmod, which would reach a hard-linked file too.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
}
