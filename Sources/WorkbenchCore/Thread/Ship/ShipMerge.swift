import Foundation

/// The shipped pull request as GitHub says it is now: open or ended, the commit it is at, and its CI.
public struct PRStatus: Sendable, Equatable {
    public var number: Int
    public var state: PRState
    public var head: String
    /// nil when the checks could not be read (`checksError` says why) or the pull request has ended.
    public var checks: PRChecksSummary?
    public var checksError: String?

    public init(number: Int, state: PRState, head: String, checks: PRChecksSummary?, checksError: String? = nil) {
        (self.number, self.state, self.head, self.checks, self.checksError) = (number, state, head, checks, checksError)
    }

    /// Open and every check passed. No checks, checks still running, a failure or checks that could not be read are not green.
    public var canMerge: Bool { state == .open && checksError == nil && checks?.state == .passed }

    /// Why Merge is not offered, in words; nil when it is.
    public var mergeBlocker: String? {
        switch state {
        case .merged: return "The pull request is merged."
        case .closed: return "The pull request was closed without merging."
        case .open: break
        }
        if checksError != nil { return "CI status is unavailable, so it is not known to be green." }
        switch checks?.state {
        case .passed?: return nil
        case .pending?: return "CI is still running."
        case .failed?: return "CI failed."
        case .none?: return "No CI checks were reported, so it is not known to be green."
        case nil: return "CI status is unavailable, so it is not known to be green."
        }
    }
}

/// Why a merge did not happen. Nothing is merged when one is thrown, as far as GitHub said.
public enum PRMergeError: Error, Equatable, CustomStringConvertible {
    /// Checked again just before merging, the pull request was not open with green CI on the commit that was shown.
    case notReady(String)
    /// `gh pr merge` refused or failed.
    case refused(String)
    /// `gh pr merge` answered, and GitHub still does not say merged.
    case notMerged(PRState)

    public var description: String {
        switch self {
        case .notReady(let why): "Not merged: \(why)"
        case .refused(let why): "GitHub refused the merge: \(why)"
        case .notMerged(let state): "The merge did not go through: GitHub says the pull request is \(state.rawValue)."
        }
    }
}

extension ThreadService {
    /// The recorded pull request's state and head (`gh pr view`), and, while it is open, its checks (`gh pr checks`). Read only.
    /// A state that cannot be read throws; checks that cannot be read come back as `checksError`, never as green.
    public func prStatus(
        id: String, gh: GitRunner?, callTimeout: TimeInterval = ThreadService.watchCallTimeout
    ) async throws -> PRStatus {
        let recorded = try recordedPR(id: id, gh: gh)
        let (state, head): (PRState, String)
        switch await prState(number: recorded.number, gh: gh) {
        case .success(let found): (state, head) = found
        case .failure(let why): throw ShipError.ghFailed(why.why)
        }
        var status = PRStatus(number: recorded.number, state: state, head: head, checks: nil)
        guard state == .open else { return status }
        let runner = GitRunner(executable: recorded.gh.executable, environment: recorded.environment, timeout: callTimeout)
        do { status.checks = try await pollChecks(number: recorded.number, runner: runner) } catch {
            status.checksError = "\(error)"
        }
        return status
    }

    /// Merges the recorded pull request with `gh pr merge --squash`, only when it is still open with green CI at `head`, the commit
    /// whose checks were shown: `--match-head-commit` makes GitHub refuse it too if a commit lands in between. The state is read
    /// again after, and only GitHub saying `merged` is a merge.
    public func mergePR(
        id: String, gh: GitRunner?, head: String, timeout: TimeInterval = ThreadService.prTimeout
    ) async throws -> PRStatus {
        guard head.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            throw PRMergeError.notReady("'\(head)' is not a commit")
        }
        let before = try await prStatus(id: id, gh: gh)
        if let blocker = before.mergeBlocker { throw PRMergeError.notReady(blocker) }
        guard before.head == head else {
            throw PRMergeError.notReady("a commit was pushed to the pull request since its CI was shown.")
        }
        let recorded = try recordedPR(id: id, gh: gh)
        let runner = GitRunner(executable: recorded.gh.executable, environment: recorded.environment, timeout: timeout)
        let result: GitResult
        do {
            result = try await runner.run(
                ["pr", "merge", String(recorded.number), "--squash", "--match-head-commit", head], in: project.root)
        } catch GitError.timedOut(_, let seconds) {
            throw PRMergeError.refused("`gh pr merge` did not answer in \(Int(seconds))s")
        } catch { throw ShipError.ghMissing }
        guard result.succeeded else {
            let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = String(Self.withoutCredentials(text, environment: runner.environment).suffix(500))
            throw PRMergeError.refused(shown.isEmpty ? "`gh pr merge` exited \(result.status)" : shown)
        }
        let after = try await prStatus(id: id, gh: gh)
        guard after.state == .merged else { throw PRMergeError.notMerged(after.state) }
        return after
    }
}
