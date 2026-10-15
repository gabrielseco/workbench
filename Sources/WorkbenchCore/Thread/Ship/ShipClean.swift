import Foundation

/// What GitHub says about a thread's recorded pull request.
public enum PRState: String, Sendable, Equatable {
    case open, merged, closed
}

/// What `clean` found for one shipped thread, and what it did (or, in a dry run, would do).
public struct CleanReport: Sendable, Equatable {
    public enum Branch: Sendable, Equatable {
        case removed
        case wouldRemove
        case kept(String)
        case absent
    }

    public var id: String
    /// nil when GitHub could not be asked; `note` says why.
    public var state: PRState?
    public var worktree: ShipCleanup?
    public var branch: Branch
    public var note: String?

    /// Something was found, removed or went wrong: worth a line. A thread with nothing left is not.
    public var hasWork: Bool { state != nil || note != nil || worktree != nil || branch != .absent }
}

extension ThreadService {
    /// Looks at one shipped thread and, unless `dryRun`, removes its worktree and local branch when its
    /// pull request is merged (or closed, with `includeClosed`). Never forces. Nothing is removed unless
    /// GitHub's head for the PR is the commit `pr.opened` recorded and the local branch is still at it, so
    /// work added after shipping is never deleted. Returns nil for a thread that was not shipped.
    public func cleanMerged(
        id: String, gh: GitRunner?, includeClosed: Bool, dryRun: Bool
    ) async -> CleanReport? {
        guard SafeNames.isThreadID(id) else { return nil }
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        guard let opened = events.last(where: { $0.kind == .prOpened }) else { return nil }
        var report = CleanReport(id: id, state: nil, worktree: nil, branch: .absent)

        guard let number = opened.data["number"]?.intValue, number > 0,
            let head = opened.data["head_sha"]?.stringValue,
            head.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil
        else {
            report.note = "its log has no usable pull request record"
            return report
        }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        let hasWorktree = manager.exists(id)
        let hasBranch = (try? await manager.branchExists(id)) ?? true
        guard hasWorktree || hasBranch else {
            return report
        }

        let lookup = await prState(number: number, gh: gh)
        let (state, remoteHead): (PRState, String)
        switch lookup {
        case .failure(let why):
            report.note = why.why
            report.branch = hasBranch ? .kept("the pull request state is unknown") : .absent
            return report
        case .success(let found): (state, remoteHead) = found
        }
        report.state = state
        switch state {
        case .open:
            report.branch = hasBranch ? .kept("the pull request is open") : .absent
            return report
        case .closed where !includeClosed:
            report.branch = hasBranch ? .kept("closed without merging; --closed removes it") : .absent
            return report
        default: break
        }
        guard remoteHead == head else {
            report.note = "the pull request's head is not the shipped commit, so nothing was removed"
            report.branch = hasBranch ? .kept("the pull request moved on after shipping") : .absent
            return report
        }

        if hasWorktree, !dryRun {
            report.worktree = await cleanShipped(id: id, gh: gh, requireOrigin: false)
        } else if hasWorktree {
            report.worktree = .kept("dry run: removed only if clean and at the shipped commit")
        }
        report.branch = await removeLocalBranch(
            id: id, head: head, reason: state.rawValue, manager: manager,
            hasBranch: hasBranch, worktreeLeft: !dryRun && manager.exists(id), dryRun: dryRun)
        return report
    }

    private func removeLocalBranch(
        id: String, head: String, reason: String, manager: WorktreeManager,
        hasBranch: Bool, worktreeLeft: Bool, dryRun: Bool
    ) async -> CleanReport.Branch {
        guard hasBranch else { return .absent }
        if worktreeLeft { return .kept("its worktree is still there") }
        let ref = "refs/heads/" + WorktreeManager.branch(for: id)
        guard let result = try? await git.run(["rev-parse", "--verify", "--quiet", ref], in: project.root),
            result.succeeded
        else { return .kept("git could not read the branch") }
        guard result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == head else {
            return .kept("it has commits after the shipped one")
        }
        if dryRun { return .wouldRemove }
        do { try await manager.deleteBranch(threadID: id) } catch {
            return .kept("git would not delete it: \(Self.withoutCredentials("\(error)"))")
        }
        do {
            try await withLog(id) { log in
                _ = try await log.append(.branchRemoved, data: ["reason": .string(reason), "head_sha": .string(head)])
            }
        } catch {
            return .kept("the branch is deleted but the log could not be written (\(error))")
        }
        return .removed
    }

    /// `gh pr view <number> --json state,headRefOid` from the project root, so a removed worktree does not
    /// matter. Any answer that is not exactly that shape is a failure, never "open".
    private func prState(number: Int, gh: GitRunner?) async -> Result<(PRState, String), CleanLookupError> {
        guard let gh else { return .failure(CleanLookupError("`gh` was not found")) }
        var environment = gh.environment
        environment["GH_REPO"] = nil
        let runner = GitRunner(executable: gh.executable, environment: environment, timeout: ThreadService.prTimeout)
        let result: GitResult
        do {
            result = try await runner.run(
                ["pr", "view", String(number), "--json", "state,headRefOid"], in: project.root)
        } catch GitError.timedOut(_, let seconds) {
            return .failure(CleanLookupError("`gh pr view` did not answer in \(Int(seconds))s"))
        } catch { return .failure(CleanLookupError("`gh` could not be run")) }
        guard result.succeeded else {
            let why = Self.withoutCredentials(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), environment: environment)
            return .failure(CleanLookupError(why.isEmpty ? "`gh pr view` exited \(result.status)" : String(why.suffix(300))))
        }
        guard let data = result.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = json["state"] as? String, let state = PRState(rawValue: raw.lowercased()),
            let oid = json["headRefOid"] as? String
        else { return .failure(CleanLookupError("`gh pr view` did not answer with a state and a head")) }
        return .success((state, oid))
    }
}

struct CleanLookupError: Error, Equatable {
    var why: String
    init(_ why: String) { self.why = why }
}

extension CleanReport {
    /// One line per fact, ready to print.
    public func render() -> [String] {
        var lines = ["\(id)  \(state.map(\.rawValue) ?? "unknown")"]
        switch worktree {
        case .removed(let path): lines.append("  worktree: removed \(path)")
        case .kept(let why): lines.append("  worktree: kept (\(why))")
        case .alreadyGone, .notShipped, nil: break
        }
        switch branch {
        case .removed: lines.append("  branch:   removed \(WorktreeManager.branch(for: id))")
        case .wouldRemove: lines.append("  branch:   would remove \(WorktreeManager.branch(for: id))")
        case .kept(let why): lines.append("  branch:   kept (\(why))")
        case .absent: break
        }
        if let note { lines.append("  note:     \(note)") }
        return lines
    }
}
