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
        try write("committed\n", to: "committed.txt", id: id, in: fx)
        _ = try await fx.git.run(["add", "committed.txt"], in: worktree)
        _ = try await fx.git.run(["commit", "-q", "-m", "c"], in: worktree)
        try write("staged\n", to: "staged.txt", id: id, in: fx)
        _ = try await fx.git.run(["add", "staged.txt"], in: worktree)
        try write("loose\n", to: "dir/loose.txt", id: id, in: fx)

        let review = try await cli(["review"], in: fx)
        #expect(review.exit?.termination == .exited(0), "\(review.text)")
        let text = review.text
        #expect(text.contains("thread:    \(id)"), "\(text)")
        #expect(text.contains("[c1] ☐ a.txt contains the word hello."), "criteria are listed: \(text)")
        #expect(text.contains("proof: cat a.txt"), "\(text)")
        #expect(text.contains("(approved)"), "\(text)")
        let checkLine = try #require(review.lines.first { $0.hasPrefix("Check ") })
        #expect(checkLine.hasPrefix("Check      failed (exit 3)  turn 1  "), "\(checkLine)")
        #expect(checkLine.hasSuffix("s  log: checks/turn-1.log"), "\(checkLine)")
        #expect(text.contains("4 files  +4 −0"), "\(text)")
        #expect(review.lines.last == #"accept | send-back "<note>" | discard"#, "the next step is the last line")
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
        try write("half done\n", to: "half.txt", id: id, in: fx)
        _ = try await log.recoverOrphanedTurn()
        await log.close()

        let review = try await cli(["review"], in: fx)
        #expect(review.text.contains("last interrupted"), "\(review.text)")
        #expect(review.text.contains("half.txt  +1 −0"), "partial work shows: \(review.text)")
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
        #expect(review.text.contains("506 files; +499 −0 in the 500 listed"), "totals say what they cover")
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
        let unknown = try await cli(["review", "no-such-thread"], in: fx)
        #expect(unknown.exit?.termination == .exited(1), "a typo is an error: \(unknown.text)")
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

    @Test func aStoppedTurnStillReviewsWithItsPartialDiff() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let ready = FakeClaude.scratch("review-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        let runner = fx.runner(id)
        let options = fx.options("ready=\(ready)", "hang-after=1")
        let task = Task { try await runner.run(options) }
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: ready), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try write("so far\n", to: "so-far.txt", id: id, in: fx)
        await runner.stop()
        #expect(try await task.value.result == .stopped)

        let review = try await cli(["review"], in: fx)
        #expect(review.text.contains("last stopped"), "\(review.text)")
        #expect(review.text.contains("so-far.txt"), "\(review.text)")
        #expect(review.lines.last == #"accept | send-back "<note>" | discard"#)
    }

    @Test func aFileBeyondTheListedCapStillHasItsPatch() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        for i in 0..<(DiffProvider.fileLimit + 5) { try write("x\n", to: "a/f\(i).txt", id: id, in: fx) }
        try write("last one\n", to: "zzz-last.txt", id: id, in: fx)

        let list = try await cli(["review"], in: fx)
        #expect(!list.text.contains("zzz-last.txt"), "cut from the list")
        let patch = try await cli(["review", "--patch", "zzz-last.txt"], in: fx)
        #expect(patch.exit?.termination == .exited(0), "\(patch.text)")
        #expect(patch.text.contains("+last one"), "\(patch.text)")
    }

    @Test func anInvalidGoalFileIsShownNotPresentedAsNoCriteria() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        try "not a goal file\n".write(to: fx.project.goalURL(id), atomically: true, encoding: .utf8)

        let review = try await cli(["review"], in: fx)
        #expect(review.text.contains("goal file not valid, criteria unknown"), "\(review.text)")
        #expect(!review.text.contains("(none)"), "\(review.text)")
    }
}

// MARK: rendering without a process

@Suite struct ReviewReportRenderingTests {
    private func report(denied: [(tool: String, seq: Int)]) -> ReviewReport {
        var state = ThreadState.derive(from: [], id: "t")
        state.review.status = .awaitingReview
        state.review.deniedTools = denied.map { Review.DeniedTool(turn: 1, tool: $0.tool, seq: $0.seq, input: nil) }
        return ReviewReport(
            state: state, title: "T", criteria: [], approval: "approved", goalProblem: nil,
            diff: .unavailable(reason: "x"))
    }

    @Test func deniedToolsAreGroupedByNameWithTheirSeq() {
        let lines = report(denied: [("Bash", 5), ("Write", 6), ("Bash", 9)]).render()
        #expect(lines.contains("Denied     3 tool calls"), "\(lines)")
        #expect(lines.contains("  Bash ×2  turn 1, seq 5, 9"), "\(lines)")
        #expect(lines.contains("  Write ×1  turn 1, seq 6"), "\(lines)")
    }
}
