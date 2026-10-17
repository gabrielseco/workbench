import Foundation

extension ThreadService {
    /// The commit `origin` has for a branch.
    func originBranchTip(_ branch: String) async throws -> String {
        let result: GitResult
        do { result = try await git.run(["ls-remote", "origin", "refs/heads/\(branch)"], in: project.root) } catch {
            throw PRReviewRefusal.originUnreadable("\(error)")
        }
        guard result.succeeded else {
            throw PRReviewRefusal.originUnreadable(Self.withoutCredentials(result.stderr.firstLine))
        }
        guard let sha = Self.firstSHA(result.stdout) else { throw PRReviewRefusal.branchGone(branch) }
        return sha
    }

    /// The commit a thread's own branch is at, for a stage that runs before the pull request exists.
    func localBranchTip(_ branch: String) async throws -> String {
        let result = try? await git.run(["rev-parse", "--verify", "refs/heads/\(branch)^{commit}"], in: project.root)
        guard let result, result.succeeded, let sha = Self.firstSHA(result.stdout) else {
            throw PRReviewRefusal.branchGone(branch)
        }
        return sha
    }

    /// Brings the pull request's branch into this repository and checks it is still the commit the round began with.
    /// The branch on origin is the pull request's head the moment a push lands; GitHub's own `pull/<n>/head` and its API
    /// lag behind it, so they are not read.
    func fetchBranch(_ round: PRReviewRound) async -> String? {
        let fetch = try? await git.run(
            ["fetch", "--quiet", "--no-tags", "origin", "refs/heads/\(round.branch)"], in: project.root)
        guard let fetch, fetch.succeeded else {
            let why = Self.withoutCredentials(fetch?.stderr.firstLine ?? "git failed")
            return "the pull request's branch could not be fetched: \(why)"
        }
        let head = try? await git.run(["rev-parse", "--verify", "FETCH_HEAD^{commit}"], in: project.root)
        guard let head, head.succeeded, Self.firstSHA(head.stdout) == round.tip else {
            return "the branch moved while the review was starting; nothing was reviewed. Run it again."
        }
        return nil
    }
}
