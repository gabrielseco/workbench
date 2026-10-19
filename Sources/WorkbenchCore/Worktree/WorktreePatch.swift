import Foundation

/// One patch file written by `WorktreePatch`.
public struct PatchFile: Sendable, Equatable {
    public var url: URL
    public var bytes: Int
    public var sha256: String
}

/// The uncommitted work of a worktree, saved before the worktree is removed.
public struct SavedPatch: Sendable, Equatable {
    /// Everything in the working tree that is not committed: tracked changes, staged ones and untracked files.
    public var working: PatchFile
    /// What the index holds that the working tree does not (a version staged and edited again, a staged file whose
    /// working copy is gone), kept apart because no patch of the working tree can say it. Nil when there is none.
    public var staged: PatchFile?
    /// The tree of everything in the worktree when the patch was taken, so a caller can tell whether it changed since.
    public var tree: String
    /// The commit the patches apply to: `HEAD` of the worktree, which is the tip of the kept branch.
    public var head: String

    public var url: URL { working.url }
    public var bytes: Int { working.bytes }
    public var sha256: String { working.sha256 }
}

public enum WorktreePatchError: Error, Equatable, Sendable, CustomStringConvertible {
    case tooLarge(bytes: Int, limit: Int)
    case gitFailed(String)
    case writeFailed(String)
    case notApplicable(String)

    public var description: String {
        switch self {
        case .tooLarge(let bytes, let limit):
            "the uncommitted changes are about \(bytes >> 20) MiB, over the \(limit >> 20) MiB Workbench saves"
        case .gitFailed(let message): "git could not describe the uncommitted changes: \(message)"
        case .writeFailed(let message): "the changes could not be saved: \(message)"
        case .notApplicable(let message): "the saved patch does not apply to the branch: \(message)"
        }
    }
}

public enum WorktreePatch {
    /// What one patch may hold; a worktree with more is not abandoned, since nothing could be kept of it.
    public static let sizeLimit = 64 << 20

    /// Writes everything uncommitted in `worktree` (tracked changes, staged ones and untracked files, not ignored
    /// ones) to `destination` as a binary patch against `HEAD`, which `git apply` takes in a checkout of the branch.
    /// When the index also holds something the working tree does not, that goes to `stagedDestination`. Nil when the
    /// worktree is clean. The working patch is made in a throwaway index, so the worktree's own index and the history
    /// are untouched. Each patch is written beside its final name and moved into place, so a failure leaves neither a
    /// partial file nor an older one replaced. Attributes come from `base`, as for `ProofIdentity`, so a file the run
    /// wrote cannot pick a clean filter for `git add`.
    public static func save(
        worktree: URL, to destination: URL, stagedTo stagedDestination: URL, git: GitRunner,
        attributesFrom base: String?, limit: Int = sizeLimit
    ) async throws -> SavedPatch? {
        let index = scratchIndex()
        defer { try? FileManager.default.removeItem(at: index) }
        guard let source = await ProofIdentity.attributeSource(base, worktree: worktree, git: git) else {
            throw WorktreePatchError.gitFailed("no attribute source")
        }
        let scratch = git.using(index: index, attributesFrom: source)

        let head = try await run(git, ["rev-parse", "--verify", "--quiet", "HEAD"], worktree).trimmed

        // Read from the worktree's own index, which this changes nothing in, and before anything is staged: `git add`
        // stores each file it takes in the repository, which a worktree that cannot fit must not fill.
        let untracked = try await run(git, ["ls-files", "--others", "--exclude-standard", "-z"], worktree)
        let changed = try await run(git, ["diff", "--name-only", "-z", "--no-ext-diff", "HEAD", "--"], worktree)
        // New content is bounded here. A deleted or shortened file adds at most what the repository already holds.
        let paths = Set((untracked + changed).split(separator: "\0").map(String.init))
        let size = paths.reduce(0) { $0 + fileSize(worktree.appendingPathComponent($1)) }
        guard size <= limit else { throw WorktreePatchError.tooLarge(bytes: size, limit: limit) }
        let needsStaged = try await stagedDiffersFromWorkingTree(git, worktree)

        _ = try await run(scratch, ["read-tree", "HEAD"], worktree)
        _ = try await run(scratch, ["add", "-A"], worktree)
        let tree = try await run(scratch, ["write-tree"], worktree).trimmed
        let names = try await run(
            scratch, ["diff", "--cached", "--name-only", "-z", "--no-ext-diff", "HEAD", "--"], worktree)
        guard !names.isEmpty || needsStaged else { return nil }

        var partials: [URL] = []
        defer { partials.forEach { try? FileManager.default.removeItem(at: $0) } }
        let working = try await write(
            of: scratch, to: destination, partials: &partials, git: git, worktree: worktree, limit: limit)
        var staged: Written?
        if needsStaged {
            // The worktree's own index against `HEAD`: blobs `git add` already stored, so nothing new is bounded here.
            staged = try await write(
                of: git, to: stagedDestination, partials: &partials, git: git, worktree: worktree, limit: limit)
        }
        try move(working)
        if let staged { try move(staged) }
        return SavedPatch(working: working.file, staged: staged?.file, tree: tree, head: head)
    }

    /// A path staged as changed whose working-tree content is not what the index holds (edited again, or deleted
    /// from disk): the working patch carries the working version, so the staged one needs its own. Renames are
    /// not detected, so each side of one is a path of its own.
    private static func stagedDiffersFromWorkingTree(_ git: GitRunner, _ worktree: URL) async throws -> Bool {
        let staged = try await run(
            git, ["diff", "--cached", "--name-only", "-z", "--no-renames", "--no-ext-diff", "HEAD", "--"], worktree)
        guard !staged.isEmpty else { return false }
        let working = try await run(
            git, ["diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--"], worktree)
        return !Set(staged.split(separator: "\0")).isDisjoint(with: Set(working.split(separator: "\0")))
    }

    /// Writes `HEAD` against `runner`'s index to a file beside `destination`, checks it applies, and returns where it
    /// is and what is in it. `partials` collects the file so a failure anywhere removes it.
    private static func write(
        of runner: GitRunner, to destination: URL, partials: inout [URL], git: GitRunner, worktree: URL, limit: Int
    ) async throws -> Written {
        let directory = destination.deletingLastPathComponent()
        let partial = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw WorktreePatchError.writeFailed("cannot create a file in \(directory.path)")
            }
        } catch let error as WorktreePatchError {
            throw error
        } catch {
            throw WorktreePatchError.writeFailed(error.localizedDescription)
        }
        partials.append(partial)
        // `--src-prefix` and `--dst-prefix` keep a `diff.noprefix` or `diff.mnemonicPrefix` setting from writing
        // paths that plain `git apply` cannot read.
        _ = try await run(
            runner,
            ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--no-color",
             "--src-prefix=a/", "--dst-prefix=b/", "--output=\(partial.path)", "HEAD", "--"], worktree)
        try await requireApplies(partial, worktree: worktree, git: git)
        guard let digest = ProofCollector.sha256(of: partial, limit: limit * 2) else {
            throw WorktreePatchError.tooLarge(bytes: fileSize(partial), limit: limit)
        }
        return Written(
            partial: partial, file: PatchFile(url: destination, bytes: digest.bytes, sha256: digest.hex))
    }

    /// A patch written beside its final name, not yet moved there.
    private struct Written {
        var partial: URL
        var file: PatchFile
    }

    private static func move(_ written: Written) throws {
        let partial = written.partial
        let destination = written.file.url
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: destination)
            }
        } catch {
            throw WorktreePatchError.writeFailed(error.localizedDescription)
        }
    }

    /// The patch must apply to `HEAD` before anything is removed on the strength of it: checked against a fresh
    /// throwaway index, so no file is touched.
    private static func requireApplies(_ patch: URL, worktree: URL, git: GitRunner) async throws {
        let index = scratchIndex()
        defer { try? FileManager.default.removeItem(at: index) }
        let scratch = git.using(index: index, attributesFrom: nil)
        _ = try await run(scratch, ["read-tree", "HEAD"], worktree)
        let result: GitResult
        do { result = try await scratch.run(["apply", "--cached", "--check", patch.path], in: worktree) } catch {
            throw WorktreePatchError.gitFailed("git apply \(error)")
        }
        guard result.succeeded else {
            throw WorktreePatchError.notApplicable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func scratchIndex() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wb-index-\(UUID().uuidString)")
    }

    private static func run(_ git: GitRunner, _ args: [String], _ directory: URL) async throws -> String {
        let result: GitResult
        do { result = try await git.run(args, in: directory) } catch {
            throw WorktreePatchError.gitFailed("git \(args.first ?? "") \(error)")
        }
        guard result.succeeded, !result.outputTruncated else {
            let why = result.outputTruncated ? "its output was cut" : result.stderr
            throw WorktreePatchError.gitFailed("git \(args.first ?? "") failed: \(why)")
        }
        return result.stdout
    }

    private static func fileSize(_ url: URL) -> Int {
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (values?[.size] as? Int) ?? 0
    }
}

extension GitRunner {
    /// The same git, reading and writing `index` instead of the worktree's own, and reading attributes from
    /// `attributesFrom` when given.
    fileprivate func using(index: URL, attributesFrom source: String?) -> GitRunner {
        var env = environment
        env["GIT_INDEX_FILE"] = index.path
        if let source { env["GIT_ATTR_SOURCE"] = source }
        return GitRunner(executable: executable, environment: env, timeout: timeout)
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
