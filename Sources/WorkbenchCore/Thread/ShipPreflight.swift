import Foundation

/// Why a thread cannot be shipped. Each case is one thing to fix; nothing was changed when it is thrown.
public enum ShipError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAccepted(String)
    case alreadyShipped(url: String)
    case running(pid: Int32)
    case worktreeMissing(String)
    case wrongBranch(expected: String, found: String)
    case uncommitted([String])
    case goalUnreadable(String)
    case invalidName(String)
    case noOrigin
    case remoteUnreachable(String)
    case ghMissing
    case ghNotAuthenticated
    case remoteDiverged(sha: String)
    case gitFailed(String)

    public var description: String {
        switch self {
        case .notAccepted(let why): "this thread is not accepted (\(why)). Only an accepted thread is shipped."
        case .alreadyShipped(let url): "this thread was already shipped: \(url)"
        case .running(let pid): "a run is still working on this thread (pid \(pid)). `workbench stop` it first."
        case .worktreeMissing(let path): "no worktree at \(path), so there is nothing to push"
        case .wrongBranch(let expected, let found):
            "the worktree is on \(found.isEmpty ? "a detached HEAD" : found), not \(expected). Nothing was pushed."
        case .uncommitted(let lines):
            "the worktree has uncommitted changes (\(lines.prefix(3).joined(separator: ", "))). "
                + "Nothing was pushed; accept again or clean it up."
        case .goalUnreadable(let why): "the goal cannot be read, so the base is unknown: \(why)"
        case .invalidName(let name): "'\(name)' is not a usable name to pass to git"
        case .noOrigin: "this repository has no remote named origin. Add one with `git remote add origin <url>`."
        case .remoteUnreachable(let why): "origin could not be read: \(why)"
        case .ghMissing: "`gh` is not installed or not on PATH. Install it (https://cli.github.com) and run `gh auth login`."
        case .ghNotAuthenticated: "`gh` is not logged in. Run `gh auth login`."
        case .remoteDiverged(let sha):
            "origin already has this branch at \(sha.prefix(12)), which is not part of this one. "
                + "Shipping would need a force push, and Workbench never does that."
        case .gitFailed(let what): what
        }
    }
}

/// What `ship` would push, when preflight allows it.
public struct ShipPlan: Sendable, Equatable {
    public enum Remote: Sendable, Equatable {
        /// `origin` has no such branch.
        case absent
        /// `origin` has exactly our tip: nothing to push.
        case upToDate
        /// `origin` has an ancestor of our tip: a plain push moves it forward.
        case behind(sha: String)
    }

    public var id: String
    public var worktree: URL
    public var branch: String
    public var base: String
    /// Our tip.
    public var head: String
    /// The URL of `origin` with any credentials removed, safe to print and to record.
    public var origin: String
    public var remote: Remote
}

extension ThreadService {
    /// Decides whether `id` can be shipped and says what would be pushed. Reads only: no push, no fetch, no
    /// write to the repository or the log. `gh` is nil when it is not installed.
    public func shipPreflight(id: String, gh: GitRunner?) async throws -> ShipPlan {
        guard SafeNames.isThreadID(id) else { throw ShipError.invalidName(id) }
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        guard !events.isEmpty else { throw ShipError.notAccepted("no such thread") }

        let state = ThreadState.derive(from: events, id: id)
        guard state.decision == "accepted" else {
            throw ShipError.notAccepted(state.decision ?? "it is still active")
        }
        if let opened = events.last(where: { $0.kind == .prOpened }) {
            throw ShipError.alreadyShipped(url: opened.data["url"]?.stringValue ?? "(no url recorded)")
        }
        if let pid = runnerPID(id: id) { throw ShipError.running(pid: pid) }

        // The base comes from the goal that was approved, and is checked like every name that reaches git.
        let base: String
        do {
            let text = try String(contentsOf: project.goalURL(id), encoding: .utf8)
            base = try GoalFile.parse(text).goal.base
        } catch {
            throw ShipError.goalUnreadable("\(error)")
        }
        let branch = WorktreeManager.branch(for: id)
        guard SafeNames.isBranchName(base) else { throw ShipError.invalidName(base) }
        guard SafeNames.isBranchName(branch) else { throw ShipError.invalidName(branch) }

        let manager = WorktreeManager(repoRoot: project.root, git: git)
        guard manager.exists(id) else { throw ShipError.worktreeMissing(manager.path(for: id).path) }
        let worktree = manager.path(for: id)

        let onBranch = try await run(["symbolic-ref", "--short", "-q", "HEAD"], in: worktree)
        let found = onBranch.succeeded ? onBranch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard found == branch else { throw ShipError.wrongBranch(expected: branch, found: found) }

        let pending: [String]
        do { pending = try await Self.pendingChanges(in: worktree, git: git) } catch {
            throw ShipError.gitFailed("cannot read the worktree's changes: \(error)")
        }
        guard pending.isEmpty else { throw ShipError.uncommitted(pending) }

        let originResult = try await run(["remote", "get-url", "origin"], in: worktree)
        guard originResult.succeeded else { throw ShipError.noOrigin }
        let origin = Self.withoutCredentials(originResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !origin.isEmpty else { throw ShipError.noOrigin }

        guard let gh else { throw ShipError.ghMissing }
        // Only the exit status is used: what `gh` prints about the account stays out of messages and logs.
        let auth: GitResult
        do { auth = try await gh.run(["auth", "status"], in: worktree) } catch GitError.timedOut {
            throw ShipError.gitFailed("`gh auth status` did not answer in time")
        } catch { throw ShipError.ghMissing }
        guard auth.succeeded else { throw ShipError.ghNotAuthenticated }

        let headResult = try await run(["rev-parse", "HEAD"], in: worktree)
        guard headResult.succeeded else { throw ShipError.gitFailed("git could not read HEAD of \(branch)") }
        let head = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        return ShipPlan(
            id: id, worktree: worktree, branch: branch, base: base, head: head, origin: origin,
            remote: try await remoteState(branch: branch, head: head, worktree: worktree))
    }

    /// Reads `origin`'s copy of the branch. No fetch: a commit that is not in this repository cannot be an
    /// ancestor of ours, which is the answer that refuses.
    private func remoteState(branch: String, head: String, worktree: URL) async throws -> ShipPlan.Remote {
        let listed = try await run(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"], in: worktree)
        guard listed.succeeded else {
            let detail = Self.withoutCredentials(
                listed.stderr.split(separator: "\n").first.map(String.init) ?? "git ls-remote failed")
            throw ShipError.remoteUnreachable(detail)
        }
        let line = listed.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let sha = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !sha.isEmpty else { return .absent }
        guard sha.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            throw ShipError.remoteUnreachable("unexpected answer from origin")
        }
        if sha == head { return .upToDate }
        let ancestor = try await run(["merge-base", "--is-ancestor", sha, head], in: worktree)
        guard ancestor.status == 0 else { throw ShipError.remoteDiverged(sha: sha) }
        return .behind(sha: sha)
    }

    private func run(_ arguments: [String], in directory: URL) async throws -> GitResult {
        do { return try await git.run(arguments, in: directory) } catch GitError.timedOut(_, let seconds) {
            throw ShipError.gitFailed("`git \(arguments.first ?? "")` did not finish in \(Int(seconds))s")
        } catch {
            throw ShipError.gitFailed("git could not be run: \(error)")
        }
    }

    /// `https://user:token@host/x` becomes `https://host/x`, wherever it appears in a line.
    static func withoutCredentials(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<=://)[^/@\s]+@"#, with: "", options: .regularExpression)
    }
}
