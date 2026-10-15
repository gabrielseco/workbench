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
    case pushDestinationDiffers
    case ghMissing
    case ghNotAuthenticated
    case remoteDiverged(sha: String)
    case gitFailed(String)
    case pushRejected(String)
    case notPushed(String)
    case ghFailed(String)
    case changedSinceShown
    case changedAfterPush
    case notShipped
    case pushTargetMissing(String)
    case branchMoved(branch: String, sha: String)
    case noPullRequest(String)
    case pullRequestBehind(pr: String)
    case pullRequestTextChanged
    case ghEditFailed(String)

    public var description: String {
        switch self {
        case .notAccepted(let why):
            "this thread is not accepted (\(why)). Only an accepted thread is shipped: "
                + "`workbench accept` ends a thread with its work committed."
        case .changedSinceShown:
            "the thread, its branch or origin changed after the plan was shown, so nothing was published. "
                + "Run `workbench ship` again."
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
        case .pushDestinationDiffers:
            "origin pushes somewhere other than where it fetches (a push URL, or several), so what was read "
                + "from it says nothing about where a push would go. Make them one URL, then ship."
        case .ghMissing: "`gh` is not installed or not on PATH. Install it (https://cli.github.com) and run `gh auth login`."
        case .ghNotAuthenticated: "`gh` is not logged in. Run `gh auth login`."
        case .remoteDiverged(let sha):
            "origin already has this branch at \(sha.prefix(12)), which is not part of this one. "
                + "Shipping would need a force push, and Workbench never does that. Look at what is on origin, "
                + "then remove or rename that remote branch yourself, or ship from a different thread."
        case .gitFailed(let what): what
        case .notPushed(let why): "the branch is not on origin at this thread's tip (\(why)). Push it first."
        case .ghFailed(let why):
            "`gh` could not open the pull request, so nothing was recorded: \(why) "
                + "Fix the cause and run `workbench ship` again; the branch is not pushed twice."
        case .notShipped:
            "this thread has no recorded pull request. Run `workbench ship` first; `--watch` follows it."
        case .changedAfterPush:
            "the branch was pushed, but the thread, its tip or origin changed before the pull request was "
                + "opened, so no PR was made. Run `workbench ship` again to see the new plan."
        case .pushTargetMissing(let branch):
            "origin no longer has \(branch), the branch this thread continues. It may have been merged and deleted. "
                + "Nothing was pushed."
        case .branchMoved(let branch, let sha):
            "origin's \(branch) is at \(sha.prefix(12)), which this thread's work does not include: it moved after "
                + "the thread started. Nothing was pushed, and Workbench never forces. Start a new thread from its "
                + "current tip with `workbench goal new <name> --update \(branch)`."
        case .noPullRequest(let branch):
            "origin has \(branch) but no open pull request uses it, and shipping a thread that continues a branch "
                + "never opens one. Nothing was recorded."
        case .pullRequestBehind(let pr):
            "GitHub still shows the pull request at \(pr.prefix(12)), not at the commit that was pushed, so it was not "
                + "recorded. Run `workbench ship` again in a moment; nothing is pushed twice."
        case .pullRequestTextChanged:
            "the pull request's title or description changed after the proposed update was made from it, so "
                + "nothing was edited. Run `workbench ship` again to see a new proposal."
        case .ghEditFailed(let why):
            "`gh` could not update the pull request text: \(why) The branch was pushed and the pull request is "
                + "recorded; edit its title and description by hand."
        case .pushRejected(let why):
            "origin did not accept the push, so nothing was shipped and the thread is still accepted: \(why)"
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
    /// The branch on `origin` that is pushed to: `branch`, or the goal's `push_to`.
    public var remoteBranch: String
    public var base: String
    /// Our tip.
    public var head: String
    /// The URL of `origin` with any credentials removed, safe to print and to record.
    public var origin: String
    public var remote: Remote
    /// The open pull request a thread that continues a branch will update; nil for any other thread.
    public var pullRequest: ExistingPR?

    /// An open pull request as `gh` reported it.
    public struct ExistingPR: Sendable, Equatable {
        public var number: Int
        public var url: String
        /// Nil when `gh` did not return the text.
        public var text: PRText?
    }

    /// True when the thread continues an existing branch, so ship pushes to it and records its open pull
    /// request instead of creating a new branch and a new pull request.
    public var updatesExistingBranch: Bool { remoteBranch != branch }

    /// `base` as a branch name for `gh pr create`: a thread cut from `origin/main` opens its pull request
    /// against `main`, since `gh` rejects a remote-tracking ref.
    public var prBase: String { base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : base }

    /// Same thread, branches, base, tip and origin: what a confirmation is about.
    public func sameTarget(as other: ShipPlan) -> Bool {
        id == other.id && branch == other.branch && remoteBranch == other.remoteBranch && base == other.base
            && head == other.head && origin == other.origin
    }
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
        let pushTo: String?
        do {
            let text = try String(contentsOf: project.goalURL(id), encoding: .utf8)
            let goal = try GoalFile.parse(text).goal
            (base, pushTo) = (goal.base, goal.pushTo)
        } catch {
            throw ShipError.goalUnreadable("\(error)")
        }
        let branch = WorktreeManager.branch(for: id)
        let remoteBranch = pushTo ?? branch
        guard SafeNames.isBranchName(base) else { throw ShipError.invalidName(base) }
        guard SafeNames.isBranchName(branch) else { throw ShipError.invalidName(branch) }
        guard pushTo == nil || SafeNames.isPushTarget(remoteBranch) else { throw ShipError.invalidName(remoteBranch) }

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

        let originResult = try await run(["remote", "get-url", "--all", "origin"], in: worktree)
        guard originResult.succeeded else { throw ShipError.noOrigin }
        let fetchURLs = Self.lines(originResult.stdout)
        guard let first = fetchURLs.first else { throw ShipError.noOrigin }
        // The branch is read from where origin fetches; the push must go to that same place.
        let pushResult = try await run(["remote", "get-url", "--all", "--push", "origin"], in: worktree)
        guard pushResult.succeeded, fetchURLs.count == 1, Self.lines(pushResult.stdout) == fetchURLs else {
            throw ShipError.pushDestinationDiffers
        }
        let origin = Self.withoutCredentials(first)

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

        let remote = try await remoteState(
            branch: remoteBranch, head: head, worktree: worktree, updating: pushTo != nil)
        var pullRequest: ShipPlan.ExistingPR?
        if pushTo != nil {
            // Before any push: a branch without an open pull request is refused with nothing changed.
            var environment = gh.environment
            environment["GH_REPO"] = nil
            let reader = GitRunner(executable: gh.executable, environment: environment, timeout: Self.prTimeout)
            guard let found = try await existingPR(branch: remoteBranch, runner: reader, worktree: worktree) else {
                throw ShipError.noPullRequest(remoteBranch)
            }
            pullRequest = ShipPlan.ExistingPR(number: found.number, url: found.url, text: found.text)
        }
        return ShipPlan(
            id: id, worktree: worktree, branch: branch, remoteBranch: remoteBranch, base: base, head: head,
            origin: origin, remote: remote, pullRequest: pullRequest)
    }

    /// Reads `origin`'s copy of the branch. No fetch: a commit that is not in this repository cannot be an
    /// ancestor of ours, which is the answer that refuses.
    private func remoteState(
        branch: String, head: String, worktree: URL, updating: Bool
    ) async throws -> ShipPlan.Remote {
        let listed = try await run(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"], in: worktree)
        guard listed.succeeded else {
            let detail = Self.withoutCredentials(
                listed.stderr.split(separator: "\n").first.map(String.init) ?? "git ls-remote failed")
            throw ShipError.remoteUnreachable(detail)
        }
        guard let sha = try Self.remoteBranchSHA(in: listed.stdout, branch: branch) else {
            if updating { throw ShipError.pushTargetMissing(branch) }
            return .absent
        }
        guard sha.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            throw ShipError.remoteUnreachable("unexpected answer from origin")
        }
        if sha == head { return .upToDate }
        let ancestor = try await run(["merge-base", "--is-ancestor", sha, head], in: worktree)
        guard ancestor.status == 0 else {
            throw updating ? ShipError.branchMoved(branch: branch, sha: sha) : ShipError.remoteDiverged(sha: sha)
        }
        return .behind(sha: sha)
    }

    private func run(_ arguments: [String], in directory: URL) async throws -> GitResult {
        do { return try await git.run(arguments, in: directory) } catch GitError.timedOut(_, let seconds) {
            throw ShipError.gitFailed("`git \(arguments.first ?? "")` did not finish in \(Int(seconds))s")
        } catch {
            throw ShipError.gitFailed("git could not be run: \(error)")
        }
    }

    /// The commit `origin` has for exactly `refs/heads/<branch>`, nil when it has none. `ls-remote` patterns
    /// match the tail of a ref name, so lookalikes come back too; and a cut-off answer proves nothing, so
    /// it is refused rather than read as "absent".
    static func remoteBranchSHA(in output: String, branch: String) throws -> String? {
        guard output.utf8.count < GitRunner.outputLimit else {
            throw ShipError.remoteUnreachable("origin listed too many matching refs to tell where the branch is")
        }
        let wanted = "refs/heads/\(branch)"
        let sha = lines(output).compactMap { line -> String? in
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            return columns.count == 2 && columns[1] == wanted ? columns[0] : nil
        }.first
        guard let sha else { return nil }
        guard sha.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            throw ShipError.remoteUnreachable("unexpected answer from origin")
        }
        return sha
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Removes what must never be shown or recorded: `user:token@` in a URL, `Authorization` headers,
    /// well-known token shapes, and `token=`-style query values. Stays conservative: it cuts, it does not guess.
    static func withoutCredentials(_ text: String) -> String {
        let patterns: [(String, String)] = [
            (#"(?<=://)[^/@\s]+@"#, ""),
            (#"(?i)(authorization:?\s*)(bearer|basic|token)?\s*[^\s,;]+"#, "$1<redacted>"),
            (#"\b(gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,})"#, "<redacted>"),
            (#"(?i)([?&](?:access_token|token|auth|key|password|secret)=)[^&\s'")]+"#, "$1<redacted>"),
        ]
        return patterns.reduce(text) {
            $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression)
        }
    }

    /// `withoutCredentials`, and also the exact values of any token in the environment `gh` was given.
    static func withoutCredentials(_ text: String, environment: [String: String]) -> String {
        var clean = withoutCredentials(text)
        for (key, value) in environment where value.count >= 6 {
            let upper = key.uppercased()
            if upper.contains("TOKEN") || upper.contains("SECRET") || upper.contains("PASSWORD") {
                clean = clean.replacingOccurrences(of: value, with: "<redacted>")
            }
        }
        return clean
    }
}
