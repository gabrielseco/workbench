import Foundation

/// What `shipPush` did.
public struct ShipPushResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case pushed
        /// `origin` already had exactly this tip.
        case alreadyOnOrigin
    }

    public var plan: ShipPlan
    public var outcome: Outcome
}

extension ThreadService {
    public static let pushTimeout: TimeInterval = 120

    /// The whole argument list of the push. Fully qualified on both sides so a tag or file of the same
    /// name is never picked up, and nothing here can force: no `-f`, no `--force*`, no `+` refspec.
    static func pushArguments(branch: String, remoteBranch: String? = nil) -> [String] {
        ["push", "--set-upstream", "origin", "refs/heads/\(branch):refs/heads/\(remoteBranch ?? branch)"]
    }

    /// Runs the preflight, then pushes `workbench/<id>` to `origin` (to the goal's `push_to` branch when it has
    /// one) with its upstream set. A rejected,
    /// timed-out or killed push changes nothing the next attempt depends on: preflight reads the remote
    /// again and a plain push is repeated. Writes no event; the PR is task 4.
    ///
    /// - Parameter shown: the plan the person confirmed. If the thread, tip, base or origin differ now,
    ///   nothing is pushed: the answer was about something else.
    public func shipPush(
        id: String, gh: GitRunner?, shown: ShipPlan? = nil, timeout: TimeInterval = ThreadService.pushTimeout
    ) async throws -> ShipPushResult {
        let plan = try await shipPreflight(id: id, gh: gh)
        if let shown, !shown.sameTarget(as: plan) || shown.remote != plan.remote {
            throw ShipError.changedSinceShown
        }
        if plan.remote == .upToDate { return ShipPushResult(plan: plan, outcome: .alreadyOnOrigin) }

        let pusher = GitRunner(executable: git.executable, environment: git.environment, timeout: timeout)
        let result: GitResult
        do {
            result = try await pusher.run(
                Self.pushArguments(branch: plan.branch, remoteBranch: plan.remoteBranch), in: plan.worktree)
        } catch GitError.timedOut(_, let seconds) {
            throw ShipError.gitFailed(
                "the push did not finish in \(Int(seconds))s and was stopped. Nothing was shipped; run it again.")
        } catch {
            throw ShipError.gitFailed("git could not be run: \(error)")
        }
        guard result.succeeded else {
            let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Redact first: cutting first could leave `user:token@host` with its `://` already gone.
            let shown = String(Self.withoutCredentials(text, environment: git.environment).suffix(2_000))
            throw ShipError.pushRejected(shown.isEmpty ? "git push exited \(result.status)" : shown)
        }
        return ShipPushResult(plan: plan, outcome: .pushed)
    }
}
