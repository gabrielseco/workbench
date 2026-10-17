import Foundation

/// The uncommitted work of a worktree, saved as one patch before the worktree is removed.
public struct SavedPatch: Sendable, Equatable {
    public var url: URL
    public var bytes: Int
    public var sha256: String
    /// The tree of everything in the worktree when the patch was taken, so a caller can tell whether it changed since.
    public var tree: String
    /// The commit the patch applies to: `HEAD` of the worktree, which is the tip of the kept branch.
    public var head: String
}

public enum WorktreePatchError: Error, Equatable, Sendable, CustomStringConvertible {
    case tooLarge(bytes: Int, limit: Int)
    case gitFailed(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .tooLarge(let bytes, let limit):
            "the uncommitted changes are about \(bytes >> 20) MiB, over the \(limit >> 20) MiB Workbench saves"
        case .gitFailed(let message): "git could not describe the uncommitted changes: \(message)"
        case .writeFailed(let message): "the changes could not be saved: \(message)"
        }
    }
}

public enum WorktreePatch {
    /// What one patch may hold; a worktree with more is not abandoned, since nothing could be kept of it.
    public static let sizeLimit = 64 << 20

    /// Writes everything uncommitted in `worktree` (tracked changes, staged ones and untracked files, not ignored
    /// ones) to `destination` as a binary patch against `HEAD`, which `git apply` takes in a checkout of the branch.
    /// Nil when the worktree is clean. Built in a throwaway index, so the worktree's own index and the history are
    /// untouched. Written beside `destination` and moved into place, so a failure leaves neither a partial patch nor
    /// an older one replaced. Attributes come from `base`, as for `ProofIdentity`, so a file the run wrote cannot
    /// pick a clean filter for `git add`.
    public static func save(
        worktree: URL, to destination: URL, git: GitRunner, attributesFrom base: String?,
        limit: Int = sizeLimit
    ) async throws -> SavedPatch? {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("wb-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        guard let source = await ProofIdentity.attributeSource(base, worktree: worktree, git: git) else {
            throw WorktreePatchError.gitFailed("no attribute source")
        }
        var environment = git.environment
        environment["GIT_INDEX_FILE"] = index.path
        environment["GIT_ATTR_SOURCE"] = source
        let scratch = GitRunner(executable: git.executable, environment: environment, timeout: git.timeout)

        let head = try await run(git, ["rev-parse", "--verify", "--quiet", "HEAD"], worktree).trimmed
        _ = try await run(scratch, ["read-tree", "HEAD"], worktree)
        _ = try await run(scratch, ["add", "-A"], worktree)
        let tree = try await run(scratch, ["write-tree"], worktree).trimmed
        let names = try await run(
            scratch, ["diff", "--cached", "--name-only", "-z", "--no-ext-diff", "HEAD", "--"], worktree)
        let paths = names.split(separator: "\0").map(String.init)
        guard !paths.isEmpty else { return nil }

        // Before git writes anything: a patch is about as large as the files it holds, so a worktree that cannot
        // fit is refused without filling the disk first.
        let size = paths.reduce(0) { $0 + fileSize(worktree.appendingPathComponent($1)) }
        guard size <= limit else { throw WorktreePatchError.tooLarge(bytes: size, limit: limit) }

        let directory = destination.deletingLastPathComponent()
        let partial = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: partial) }
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
        _ = try await run(
            scratch,
            ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--no-color",
             "--output=\(partial.path)", "HEAD", "--"], worktree)
        guard let digest = VerifyRunner.sha256(of: partial, limit: limit * 2) else {
            throw WorktreePatchError.tooLarge(bytes: fileSize(partial), limit: limit)
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: destination)
            }
        } catch {
            throw WorktreePatchError.writeFailed(error.localizedDescription)
        }
        return SavedPatch(url: destination, bytes: digest.bytes, sha256: digest.hex, tree: tree, head: head)
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

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
