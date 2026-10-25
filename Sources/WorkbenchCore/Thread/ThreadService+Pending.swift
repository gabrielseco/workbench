import Foundation

extension ThreadService {
    /// What `git status` lists in a worktree, untracked files one by one.
    static func pendingResult(in worktree: URL, git: GitRunner) async -> Result<[String], Error> {
        do { return .success(try await pendingChanges(in: worktree, git: git)) } catch { return .failure(error) }
    }

    static func pendingChanges(in worktree: URL, git: GitRunner) async throws -> [String] {
        let result = try await git.run(["status", "--porcelain", "--untracked-files=all"], in: worktree)
        guard result.succeeded else {
            throw WorktreeError.gitFailed(command: "status", status: result.status, stderr: result.stderr)
        }
        return result.stdout.split(separator: "\n").map(String.init)
    }
}
