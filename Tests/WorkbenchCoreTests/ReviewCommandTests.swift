import Foundation
import Testing

@testable import WorkbenchCore

// `workbench review` through the real CLI, against threads the fake claude ran.

private struct CLIResult {
    var lines: [String]
    var exit: ProcessExit?
    var text: String { lines.joined(separator: "\n") }
}

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> CLIResult {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
        workingDirectory: fx.repo, timeout: 60)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var result = CLIResult(lines: [], exit: nil)
    for await event in run.events {
        if case .line(let line) = event { result.lines.append(line) }
        if case .exited(let e) = event { result.exit = e }
    }
    return result
}

private func porcelainPaths(_ fx: RunnerFixture, id: String) async throws -> [String] {
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    let status = try await fx.git.run(["status", "--porcelain", "-uall"], in: worktree)
    return status.stdout.split(separator: "\n").map { String($0.dropFirst(3)) }.sorted()
}

private func write(_ text: String, to name: String, id: String, in fx: RunnerFixture) throws {
    let url = fx.project.worktreesDirectory.appendingPathComponent(id).appendingPathComponent(name)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Suite struct ReviewCommandTests {
    @Test func showsCriteriaDiffCheckAndNextStepsAfterATurn() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(try script.write("echo bad\nexit 3"))
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)

        // Modified, staged, committed and untracked work all show.
        try write("one\ntwo\n", to: "a.txt", id: id, in: fx)
        try write("staged\n", to: "staged.txt", id: id, in: fx)
        _ = try await fx.git.run(["add", "staged.txt"], in: worktree)
        try write("committed\n", to: "committed.txt", id: id, in: fx)
        _ = try await fx.git.run(["add", "committed.txt"], in: worktree)
        _ = try await fx.git.run(["commit", "-q", "-m", "c"], in: worktree)
        try write("loose\n", to: "dir/loose.txt", id: id, in: fx)

        let review = try await cli(["review"], in: fx)
        #expect(review.exit?.termination == .exited(0), "\(review.text)")
        let text = review.text
        #expect(text.contains("thread:    \(id)"), "\(text)")
        #expect(text.contains("☐"), "criteria are listed: \(text)")
        #expect(text.contains("Check      failed (exit 3)  turn 1"), "\(text)")
        #expect(text.contains("Denied     none"), "\(text)")
        #expect(text.contains("accept | send-back"), "\(text)")

        let shown = review.lines.filter { $0.hasPrefix("  ") && $0.contains("+") && $0.contains("−") && !$0.contains(" files  ") }
            .compactMap { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first.map(String.init) }
        let expected = try await porcelainPaths(fx, id: id)
        // `git status` shows a committed file only relative to HEAD, so compare with the base instead.
        let base = try await fx.git.run(["diff", "--name-only", "main"], in: worktree).stdout
            .split(separator: "\n").map(String.init)
        let untracked = try await fx.git.run(["ls-files", "--others", "--exclude-standard"], in: worktree).stdout
            .split(separator: "\n").map(String.init)
        #expect(Set(shown) == Set(base + untracked), "shown \(shown) vs \(base + untracked)")
        #expect(Set(expected).isSubset(of: Set(shown)), "status \(expected) vs shown \(shown)")
    }

    @Test func aTurnThatTimedOutStillReviewsWithItsPartialDiff() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options("hang-after=1", timeout: 0.6))
        #expect(report.result == .timedOut)
        try write("partial\n", to: "partial.txt", id: id, in: fx)

        let review = try await cli(["review"], in: fx)
        #expect(review.text.contains("last timed_out"), "\(review.text)")
        #expect(review.text.contains("partial.txt"), "\(review.text)")
        #expect(review.text.contains("accept | send-back \"<note>\" | discard"), "\(review.text)")
    }

    @Test func aTurnTheRunnerDiedInReviewsAsInterrupted() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.turnStarted, turn: 2, data: ["session_id": "s", "resume": true])
        _ = try await log.recoverOrphanedTurn()
        await log.close()

        let review = try await cli(["review"], in: fx)
        #expect(review.text.contains("last interrupted"), "\(review.text)")
        #expect(review.text.contains("accept | send-back \"<note>\" | discard"), "\(review.text)")
    }

    @Test func binaryFilesAndHugeDiffsAreSummarisedNotDumped() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try Data([0, 1, 2, 3]).write(to: worktree.appendingPathComponent("blob.bin"))
        for i in 0..<(DiffProvider.fileLimit + 5) { try write("x\n", to: "many/f\(i).txt", id: id, in: fx) }

        let review = try await cli(["review"], in: fx)
        #expect(review.text.contains("blob.bin  binary"), "binary file is one line")
        #expect(review.text.contains("too many files, showing \(DiffProvider.fileLimit) of \(DiffProvider.fileLimit + 6)"))
        #expect(review.lines.count < DiffProvider.fileLimit + 40)
    }

    @Test func patchPrintsOneFileAndFallsBackForBinaryLargeAndUnknown() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try write("one\nchanged\n", to: "a.txt", id: id, in: fx)
        try Data([0, 1]).write(to: worktree.appendingPathComponent("blob.bin"))
        try String(repeating: "line of text\n", count: 30_000).write(
            to: worktree.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        let small = try await cli(["review", "--patch", "a.txt"], in: fx)
        #expect(small.text.contains("+changed"), "\(small.text)")
        let binary = try await cli(["review", "--patch", "blob.bin"], in: fx)
        #expect(binary.text.contains("binary file: no patch"), "\(binary.text)")
        let big = try await cli(["review", "--patch", "big.txt"], in: fx)
        #expect(big.text.contains("patch too large"), "\(big.text.prefix(200))")
        let missing = try await cli(["review", "--patch", "nope.txt"], in: fx)
        #expect(missing.exit?.termination == .exited(1))
    }

    @Test func aStatusWithNothingToDecideSaysWhy() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let empty = try await cli(["review"], in: fx)
        #expect(empty.text.contains("nothing to review yet"), "\(empty.text)")

        _ = try await fx.runner(id).run(fx.options())
        var log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.threadNote, data: ["text": "again"])
        await log.close()
        let sentBack = try await cli(["review"], in: fx)
        #expect(sentBack.text.contains("feedback is recorded"), "\(sentBack.text)")
        #expect(sentBack.text.contains("Notes      1 sent back"), "\(sentBack.text)")

        log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.turnStarted, turn: 2, data: ["session_id": "s", "resume": true])
        await log.close()
        let running = try await cli(["review"], in: fx)
        #expect(running.text.contains("turn 2 is still running"), "\(running.text)")
    }

    @Test func reviewWritesNothingEvenWithATurnOpen() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.turnStarted, turn: 2, data: ["session_id": "s", "resume": true])
        // The writer stays open and holds the lock: review must not need it.
        let before = try Data(contentsOf: fx.project.eventsURL(id))
        let statusBefore = try await porcelainPaths(fx, id: id)
        let listing = try FileManager.default.contentsOfDirectory(atPath: fx.project.threadDirectory(id).path).sorted()

        let review = try await cli(["review"], in: fx)
        #expect(review.exit?.termination == .exited(0), "\(review.text)")

        #expect(try Data(contentsOf: fx.project.eventsURL(id)) == before)
        #expect(try await porcelainPaths(fx, id: id) == statusBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.project.threadDirectory(id).path).sorted() == listing)
        await log.close()
    }

    @Test func anAbandonedThreadStillReviewsFromTheLog() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        try await fx.service.abandon(id: id, force: true)

        let review = try await cli(["review", id], in: fx)
        #expect(review.exit?.termination == .exited(0), "\(review.text)")
        #expect(review.text.contains("Diff unavailable: the worktree no longer exists"), "\(review.text)")
        #expect(review.text.contains("this thread was abandoned"), "\(review.text)")
        #expect(review.text.contains("turns:     1  last succeeded"), "\(review.text)")
    }
}
