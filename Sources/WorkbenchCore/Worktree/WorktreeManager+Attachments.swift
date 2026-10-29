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
    /// would ignore the result; when it would not, it removes its own earlier files and writes nothing. It touches only names of
    /// the form `<n>.<png|jpg|gif|webp>`.
    public func writeAttachmentCopies(_ sources: [URL], for threadID: String) async -> [String] {
        guard SafeNames.isThreadID(threadID), exists(threadID) else { return [] }
        let worktree = path(for: threadID)
        let folder = worktree.appendingPathComponent(Self.attachmentCopyFolder, isDirectory: true)
        var dir = worktree
        for part in Self.attachmentCopyFolder.split(separator: "/") {
            dir = dir.appendingPathComponent(String(part), isDirectory: true)
            if let type = Self.type(of: dir), type != .typeDirectory { return [] }
        }
        let wanted = sources.map(\.lastPathComponent)
        let tracked = try? await git.run(["ls-files", "--", Self.attachmentCopyFolder], in: worktree)
        if tracked?.succeeded != true || !(tracked?.stdout.isEmpty ?? false) { return [] }
        let ignored = try? await git.run(["check-ignore", "-q", "--", Self.attachmentCopyFolder + "/1.png"], in: worktree)
        let ours = Self.ownedNames(in: folder)
        for name in ours where ignored?.succeeded != true || !wanted.contains(name) { Self.removeOwned(name, in: folder) }
        guard ignored?.succeeded == true, !sources.isEmpty else { return [] }
        var written: [String] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for source in sources {
                let name = source.lastPathComponent
                let target = folder.appendingPathComponent(name)
                if Self.type(of: target) == .typeRegular {
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
                } else if Self.type(of: target) != nil {
                    return written
                }
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
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 2 && Int(parts[0]) != nil && ["png", "jpg", "gif", "webp"].contains(String(parts[1]))
                && type(of: folder.appendingPathComponent(name)) == .typeRegular
        }
    }

    private static func removeOwned(_ name: String, in folder: URL) {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}
