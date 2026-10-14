import Foundation
import Testing

@testable import WorkbenchCore

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> (code: Int32?, text: String) {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "FAKE_CLAUDE": "",
        ],
        workingDirectory: fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return (code, (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
}

@Suite struct StartFrictionCLITests {
    @Test func initKeepsWorkbenchOutOfGitStatusEvenWhenRunTwice() async throws {
        let fx = try await RunnerFixture()
        #expect(try await cli(["init"], in: fx).code == 0)
        #expect(try await cli(["init"], in: fx).code == 0)
        #expect(try await fx.git.run(["status", "--porcelain"], in: fx.repo).stdout.isEmpty)
        let exclude = try String(contentsOf: fx.repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: ".workbench/").count == 2)
    }

    @Test func runWithALocalEditAndTheIgnoredFlagStartsAndSaysWhatWasLeftOut() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.approvedThread()
        try "local\n".write(to: fx.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let result = try await cli(["run", "--allow-dirty"], in: fx)
        #expect(result.code == 0, "\(result.text)")
        #expect(result.text.contains("note: 1 file changed in your checkout is not part of this thread"))
        let plain = try await cli(["help"], in: fx)
        #expect(plain.text.contains("--allow-dirty is ignored"))
    }

    @Test func reviewSaysTheGapAlsoOnAnEndedThread() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "w\n".write(to: worktree.appendingPathComponent("w.txt"), atomically: true, encoding: .utf8)
        try await fx.service.accept(id: id, message: "chore: x")
        let bare = fx.repo.deletingLastPathComponent().appendingPathComponent("o-\(UUID().uuidString).git")
        _ = try await fx.git.run(["init", "-q", "--bare", bare.path], in: fx.repo)
        _ = try await fx.git.run(["remote", "add", "origin", bare.path], in: fx.repo)
        _ = try await fx.git.run(["push", "-q", "origin", "main"], in: fx.repo)
        let clone = fx.repo.deletingLastPathComponent().appendingPathComponent("c-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", "-b", "main", bare.path, clone.path], in: fx.repo)
        try "x\n".write(to: clone.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: clone)
        _ = try await fx.git.run(["commit", "-q", "-m", "x"], in: clone)
        _ = try await fx.git.run(["push", "-q", "origin", "HEAD:main"], in: clone)

        let review = try await cli(["review", id], in: fx)
        #expect(review.text.contains("main is 1 commit behind origin/main"), "\(review.text)")
    }

    @Test func statusAndReviewSayHowFarTheBaseIsBehindOrigin() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let bare = fx.repo.deletingLastPathComponent().appendingPathComponent("o-\(UUID().uuidString).git")
        _ = try await fx.git.run(["init", "-q", "--bare", bare.path], in: fx.repo)
        _ = try await fx.git.run(["remote", "add", "origin", bare.path], in: fx.repo)
        _ = try await fx.git.run(["push", "-q", "origin", "main"], in: fx.repo)

        let quiet = try await cli(["status", id], in: fx)
        #expect(quiet.code == 0 && !quiet.text.contains("behind"), "\(quiet.text)")

        let clone = fx.repo.deletingLastPathComponent().appendingPathComponent("c-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", "-b", "main", bare.path, clone.path], in: fx.repo)
        try "x\n".write(to: clone.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: clone)
        _ = try await fx.git.run(["commit", "-q", "-m", "x"], in: clone)
        _ = try await fx.git.run(["push", "-q", "origin", "HEAD:main"], in: clone)

        let status = try await cli(["status", id], in: fx)
        #expect(status.text.contains("main is 1 commit behind origin/main"), "\(status.text)")
        let review = try await cli(["review", id], in: fx)
        #expect(review.text.contains("main is 1 commit behind origin/main"), "\(review.text)")
    }
}
