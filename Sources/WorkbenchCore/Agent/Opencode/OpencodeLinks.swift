import Foundation

/// OpenCode's file tools follow a symlink to wherever it points, even with `external_directory` denied
/// (docs/plan/P28-capabilities.md, "Symlinks"), so a read-only turn is only confined to its folder when nothing in the folder links
/// out of it. A checkout is made of what a branch committed: a pull request can add such a link.
enum OpencodeLinks {
    /// More entries than this are not walked: the turn is refused, never run unchecked.
    static let entryLimit = 200_000

    enum Problem: Equatable {
        /// The path, relative to the folder, of a link that resolves outside it. The target is not kept: it may name a private file.
        case outward(String)
        case unchecked(String)

        var message: String {
            let confined = "so a read-only OpenCode turn could not be kept to its folder"
            switch self {
            case .outward(let path): return "\(path) is a symlink that points outside the folder the turn reads, \(confined)"
            case .unchecked(let why): return "the folder the turn reads could not be checked for symlinks (\(why)), \(confined)"
            }
        }
    }

    /// The first reason `folder` does not confine a reader, nil when it does. Nothing in it is exempt, the run's own state included
    /// (OpenCode makes no links there). A link whose target does not resolve (it dangles, or it loops) leads nowhere that can be read.
    static func problem(in folder: URL, limit: Int = entryLimit) -> Problem? {
        let root = OrphanSweeper.realPath(folder)
        var unreadable: String?
        let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: [.isSymbolicLinkKey], options: [],
            errorHandler: { url, _ in
                unreadable = url.lastPathComponent
                return false
            })
        guard let walker else { return .unchecked("it cannot be listed") }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > limit { return .unchecked("it holds more than \(limit) entries") }
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                let resolved = realpath(url.path, nil)
            else { continue }
            let target = String(cString: resolved)
            free(resolved)
            if target != root, !target.hasPrefix(root + "/") {
                let path = url.path.hasPrefix(root + "/") ? String(url.path.dropFirst(root.count + 1)) : url.lastPathComponent
                return .outward(path)
            }
        }
        return unreadable.map { .unchecked("\($0) cannot be read") }
    }
}
