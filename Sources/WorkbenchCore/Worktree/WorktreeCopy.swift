import Foundation

/// What `copy` put into a new worktree, and what it left out.
public struct CopyReport: Sendable, Equatable {
    /// Repo-relative paths now present in the worktree.
    public var copied: [String] = []
    /// `"<path>: <reason>"` for a match that was not copied.
    public var skipped: [String] = []
}

/// Copies untracked, git-ignored files (`.env`, a local credentials file) from the main checkout into a new
/// worktree, which `git worktree add` leaves out. Patterns are repo-relative; `*` and `?` match within one
/// path component, there is no `**`.
struct WorktreeCopier: Sendable {
    static let maxFiles = 200
    /// Matches looked at in all, copied or not, and notes kept: a glob over `node_modules` must not run for long.
    static let defaultMaxMatches = 1000
    static let maxNotes = 20
    static let maxFileBytes = 1 << 20

    let source: URL
    let git: GitRunner
    var maxMatches = WorktreeCopier.defaultMaxMatches

    /// Why a pattern cannot be used, nil when it can: it ends up in a path under two checkouts.
    static func patternProblem(_ pattern: String) -> String? {
        if pattern.isEmpty || pattern.contains("\0") || pattern.contains("\n") || pattern.contains("\r") {
            return "must be a file path or glob"
        }
        if pattern.hasPrefix("/") || pattern.hasPrefix("~") || pattern.hasPrefix("-") {
            return "must be a path inside the repository"
        }
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) {
            return "must be a path inside the repository (no '.', '..' or empty parts)"
        }
        if let first = parts.first, first == ".git" || first == ".workbench" {
            return "must not point into \(first)"
        }
        return nil
    }

    func copy(_ patterns: [String], to destination: URL) async -> CopyReport {
        var report = CopyReport()
        var seen = Set<String>()
        var omitted = 0
        func skip(_ note: String) {
            if report.skipped.count < Self.maxNotes { report.skipped.append(note) } else { omitted += 1 }
        }
        for pattern in patterns {
            var budget = maxMatches - seen.count
            let parts = pattern.split(separator: "/").map(String.init)
            let matches = Self.expand(parts, under: source, relative: "", budget: &budget)
            if matches.isEmpty { skip("\(pattern): no file matches") }
            for path in matches where seen.insert(path).inserted {
                if report.copied.count >= Self.maxFiles {
                    skip("\(path): more than \(Self.maxFiles) files")
                } else if let reason = await copyOne(path, to: destination) {
                    skip("\(path): \(reason)")
                } else {
                    report.copied.append(path)
                }
            }
            if seen.count >= maxMatches { skip("\(pattern): stopped after \(maxMatches) matches"); break }
        }
        if omitted > 0 { report.skipped.append("and \(omitted) more not copied") }
        return report
    }

    /// Regular files only, never through a symlink, and only ones git ignores: anything else would show up in the
    /// diff (untracked) or is already in the worktree (tracked).
    private func copyOne(_ path: String, to destination: URL) async -> String? {
        let from = source.appendingPathComponent(path)
        let to = destination.appendingPathComponent(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: from.path),
            attrs[.type] as? FileAttributeType == .typeRegular
        else { return "not a regular file" }
        if let size = attrs[.size] as? Int, size > Self.maxFileBytes { return "larger than \(Self.maxFileBytes / 1024) KiB" }
        if Self.hasSymlink(path, under: destination) { return "a parent folder is a symlink in the worktree" }
        // Both checkouts: the worktree is cut from `base`, whose ignore rules can differ from the checkout's.
        for root in [source, destination] {
            guard let ignored = try? await git.run(["check-ignore", "-q", "--", path], in: root), ignored.status != 128
            else { return "git could not say whether it is ignored" }
            guard ignored.succeeded else { return "not ignored by git, so it would show up in the diff" }
        }
        guard !FileManager.default.fileExists(atPath: to.path) else { return "already in the worktree" }
        do {
            try FileManager.default.createDirectory(
                at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: to)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// Whether `path` or one of its parents already exists under `root` as a symlink: creating folders or a file
    /// through it would write outside the worktree.
    private static func hasSymlink(_ path: String, under root: URL) -> Bool {
        var url = root
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            if type == .typeSymbolicLink { return true }
            if type == nil { return false }
        }
        return false
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// Repo-relative paths under `dir` that match `parts`, in name order. A symlink is never followed: it is not
    /// listed as a directory to enter, and `copyOne` refuses it as a file.
    private static func expand(_ parts: [String], under dir: URL, relative: String, budget: inout Int) -> [String] {
        guard let head = parts.first else { return [] }
        let rest = Array(parts.dropFirst())
        let isGlob = head.contains("*") || head.contains("?")
        var names: [String]
        if isGlob {
            let listed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            names = listed.filter { fnmatch(head, $0, 0) == 0 }.sorted()
        } else {
            names = [head]
        }
        var out: [String] = []
        for name in names where budget > 0 && !(relative.isEmpty && (name == ".git" || name == ".workbench")) {
            let path = relative.isEmpty ? name : relative + "/" + name
            let url = dir.appendingPathComponent(name)
            if rest.isEmpty {
                if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
                    out.append(path)
                    budget -= 1
                }
            } else if isDirectory(url) {
                out += expand(rest, under: url, relative: path, budget: &budget)
            }
        }
        return out
    }
}
