import Foundation

/// Bringing the local base branch up to date with origin before a goal's worktree is cut from it.
extension WorktreeManager {
    public enum BaseUpdate: Sendable, Equatable {
        /// Nothing to update from: no `origin`, `base` is not a local branch, or origin is not known to have it.
        case skipped
        /// The local branch already had origin's tip.
        case current
        /// The local branch had commits origin does not, and nothing on origin it lacks: it is used as it is.
        case localAhead(Int)
        /// The local branch was moved forward to origin's tip.
        case fastForwarded(from: String, to: String)
    }

    /// Fetches `origin/<base>` and fast-forwards the local `base` to it, so a new goal starts from what origin has.
    ///
    /// It never loses work: a branch checked out somewhere is moved with `git merge --ff-only` in that checkout, which keeps
    /// uncommitted changes and refuses when they would be overwritten; a branch checked out nowhere is moved with a
    /// compare-and-swap `update-ref`. A branch that has diverged from origin is left as it is. Any of these, and a fetch
    /// that fails, throws `baseUpdateFailed` saying why, and the caller does not start: a goal must not quietly start from
    /// a stale base. With no `origin`, or a base origin says it does not have (a local-only branch), it does nothing.
    @discardableResult
    public func updateBaseFromOrigin(_ base: String, timeout: TimeInterval = 30) async throws -> BaseUpdate {
        guard SafeNames.isBranchName(base) else { throw WorktreeError.invalidBase(base) }
        let localRef = "refs/heads/\(base)"
        let remoteRef = "refs/remotes/origin/\(base)"
        guard (try? await git.run(["remote", "get-url", "origin"], in: repoRoot))?.succeeded == true,
            await sha(of: localRef) != nil
        else { return .skipped }
        let fetcher = GitRunner(executable: git.executable, environment: git.environment, timeout: timeout)
        // Nothing cached says origin has the branch (origin was added later, or never fetched): origin is asked, since its
        // branch may already be ahead. Only origin saying it has no such branch makes it a local one.
        let tracksOrigin = try? await git.run(["config", "--get", "branch.\(base).remote"], in: repoRoot)
        let tracked = tracksOrigin?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "origin"
        if !tracked, await sha(of: remoteRef) == nil {
            do {
                let listed = try await fetcher.run(
                    ["ls-remote", "--exit-code", "--heads", "origin", localRef], in: repoRoot)
                // `--exit-code` exits 2 when origin answered and has no matching branch.
                if listed.status == 2 { return .skipped }
                guard listed.succeeded else {
                    throw WorktreeError.baseUpdateFailed(
                        base: base, reason: "could not ask origin for it (\(Self.firstLine(listed)))")
                }
            } catch GitError.timedOut {
                throw WorktreeError.baseUpdateFailed(
                    base: base, reason: "origin did not answer in \(Int(timeout))s")
            }
        }

        let refspec = "+\(localRef):\(remoteRef)"
        do {
            let fetched = try await fetcher.run(["fetch", "--no-tags", "--quiet", "origin", refspec], in: repoRoot)
            guard fetched.succeeded else {
                throw WorktreeError.baseUpdateFailed(
                    base: base, reason: "could not fetch it from origin (\(Self.firstLine(fetched)))")
            }
        } catch GitError.timedOut {
            throw WorktreeError.baseUpdateFailed(
                base: base, reason: "origin did not answer in \(Int(timeout))s")
        }

        guard let local = await sha(of: localRef), let remote = await sha(of: remoteRef) else {
            throw WorktreeError.baseUpdateFailed(base: base, reason: "origin/\(base) could not be read after the fetch")
        }
        if local == remote { return .current }
        let ahead = await count("\(remote)..\(local)")
        let behind = await count("\(local)..\(remote)")
        guard let ahead, let behind else {
            throw WorktreeError.baseUpdateFailed(base: base, reason: "could not compare it with origin/\(base)")
        }
        if behind == 0 { return .localAhead(ahead) }
        if ahead > 0 {
            throw WorktreeError.baseUpdateFailed(
                base: base,
                reason: "it has \(Self.commits(ahead)) that origin/\(base) does not, and origin/\(base) has "
                    + "\(Self.commits(behind)) that it does not. Bring them together yourself (for example "
                    + "`git pull --rebase` on \(base)), then start the goal again")
        }

        // Fast-forward: in the checkout that has the branch, or by ref when none has.
        _ = try? await git.run(["worktree", "prune"], in: repoRoot)
        if let checkout = await checkout(of: localRef) {
            let merged = try await git.run([
                // Never stash the checkout's changes or overwrite its ignored files: either way git can "succeed" and
                // leave the person's checkout changed. Refusing is what stops the goal. Never squash either
                // (`branch.<base>.mergeOptions=--squash`): git would stage origin's changes and leave the branch where it was.
                "merge", "--ff-only", "--no-squash", "--no-autostash", "--no-overwrite-ignore", "--quiet", remote,
            ], in: checkout)
            guard merged.succeeded else {
                throw WorktreeError.baseUpdateFailed(
                    base: base,
                    reason: "it is checked out at \(checkout.path) and git would not move it forward there "
                        + "(\(Self.firstLine(merged))). Commit or set aside the changes git names, then start the goal again")
            }
            // Whatever the person's merge configuration does, the goal starts only from a branch that is at origin's tip.
            guard await sha(of: localRef) == remote else {
                throw WorktreeError.baseUpdateFailed(
                    base: base,
                    reason: "git reported moving it forward at \(checkout.path), but it is not at origin/\(base). "
                        + "Check that checkout, then start the goal again")
            }
        } else {
            let moved = try await git.run(["update-ref", localRef, remote, local], in: repoRoot)
            guard moved.succeeded else {
                throw WorktreeError.baseUpdateFailed(
                    base: base, reason: "it changed while it was being updated (\(Self.firstLine(moved)))")
            }
        }
        return .fastForwarded(from: local, to: remote)
    }

    private func sha(of ref: String) async -> String? {
        let result = try? await git.run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: repoRoot)
        guard let result, result.succeeded else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    private func count(_ range: String) async -> Int? {
        let result = try? await git.run(["rev-list", "--count", range], in: repoRoot)
        guard let result, result.succeeded else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The working tree that has `ref` checked out, if any.
    private func checkout(of ref: String) async -> URL? {
        guard let listed = try? await git.run(["worktree", "list", "--porcelain"], in: repoRoot), listed.succeeded
        else { return nil }
        var path: String?
        for line in listed.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line == "branch \(ref)", let path {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func firstLine(_ result: GitResult) -> String {
        let first = result.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(result.status)"
        return ThreadService.withoutCredentials(first)
    }

    private static func commits(_ count: Int) -> String { count == 1 ? "1 commit" : "\(count) commits" }
}
