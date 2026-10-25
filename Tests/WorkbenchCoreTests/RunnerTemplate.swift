import Foundation

@testable import WorkbenchCore

/// The repository every `RunnerFixture` starts from: `main` with one commit holding `a.txt`. Built once per test
/// process and copied, since init, add and commit are three git processes a fixture would otherwise run itself.
/// A plain repository holds no absolute path, so a copy is as good as a fresh one.
enum RunnerTemplate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var building: Task<URL, Error>?

    static func repository(git: GitRunner) async throws -> URL {
        let task = lock.withLock {
            if let building { return building }
            let task = Task { () -> URL in
                let dir = Scratch.url("template").appendingPathComponent("repo")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let root = dir.resolvingSymlinksInPath()
                _ = try await git.run(["init", "-q", "-b", "main"], in: root)
                try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
                _ = try await git.run(["add", "-A"], in: root)
                _ = try await git.run(["commit", "-q", "-m", "first"], in: root)
                return dir
            }
            building = task
            return task
        }
        return try await task.value
    }
}
