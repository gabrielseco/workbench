import Foundation
import Testing

@testable import WorkbenchCore

/// `ThreadService.syncBase`: a thread's branch brings the base's new commits in, with a real repository, a bare origin and a worktree.
@Suite(.processGate) struct SyncBaseTests {
    /// A thread with a worktree on `main` (a.txt holds `one`) and an origin that has `main`.
    private func thread(_ fx: RunnerFixture) async throws -> (id: String, worktree: URL) {
        _ = try await addOrigin(fx)
        let id = try await fx.service.newThread(name: "work", base: "main")
        let worktree = try await WorktreeManager(repoRoot: fx.repo, git: fx.git).create(threadID: id, base: "main").path
        return (id, worktree)
    }

    /// A commit on `main` in the project's own checkout, pushed to origin.
    private func landOnMain(_ fx: RunnerFixture, _ file: String, _ text: String) async throws {
        try text.write(to: fx.repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "land \(file)"], in: fx.repo)
        _ = try await fx.git.run(["push", "-q", "origin", "main"], in: fx.repo)
    }

    private func write(_ worktree: URL, _ file: String, _ text: String) throws {
        try text.write(to: worktree.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private func kinds(_ fx: RunnerFixture, _ id: String) throws -> [String] { try fx.kinds(id) }

    @Test func aBaseThatHasNotMovedChangesNothing() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await thread(fx)
        try write(worktree, "a.txt", "one\nmine\n")
        let before = try await fx.git.run(["rev-parse", "HEAD"], in: worktree).stdout

        let result = try await fx.service.syncBase(id: id)
        guard case .upToDate(let moved) = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(moved.behind == 0 && moved.line.contains("has not moved"))
        #expect(try await fx.git.run(["rev-parse", "HEAD"], in: worktree).stdout == before)
        #expect(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8) == "one\nmine\n")
        #expect(!(try kinds(fx, id).contains("base.synced")), "nothing happened, nothing is recorded")
    }

    @Test func otherFilesMergeCleanlyAndTheThreadsWorkIsKeptInACommit() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await thread(fx)
        try write(worktree, "a.txt", "one\nmine\n")
        try await landOnMain(fx, "b.txt", "theirs\n")

        let result = try await fx.service.syncBase(id: id)
        guard case .merged(let moved, let head, let saved) = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(moved.behind == 1 && moved.overlapping.isEmpty)
        #expect(moved.line.contains("none touch files this thread changed"))
        #expect(saved != nil && !head.isEmpty)
        #expect(try String(contentsOf: worktree.appendingPathComponent("b.txt"), encoding: .utf8) == "theirs\n")
        #expect(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8) == "one\nmine\n")
        let status = try await fx.git.run(["status", "--porcelain"], in: worktree)
        #expect(status.stdout.isEmpty, "the worktree is clean: \(status.stdout)")
        let parents = try await fx.git.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: worktree).stdout
        #expect(parents.split(separator: " ").count == 3, "HEAD is a merge commit")

        let event = try #require(try fx.events(id).last { $0.kind.rawValue == "base.synced" })
        #expect(event.data["result"]?.stringValue == "merged" && event.data["behind"]?.intValue == 1)
        #expect(event.data["saved_work"]?.stringValue == saved)
    }

    @Test func aFileBothChangedIsNamedEvenWhenItMergesCleanly() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await thread(fx)
        try write(worktree, "a.txt", "one\nmine\n")  // after the line they will not touch
        try await landOnMain(fx, "a.txt", "zero\none\n")  // before it

        let result = try await fx.service.syncBase(id: id)
        guard case .merged(let moved, _, _) = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(moved.overlapping == ["a.txt"])
        #expect(moved.line.contains("1 file(s) it changed were touched there too: a.txt"))
        #expect(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8) == "zero\none\nmine\n")
    }

    @Test func aConflictIsLeftInTheWorktreeForSomeoneToResolve() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await thread(fx)
        try write(worktree, "a.txt", "mine\n")
        try await landOnMain(fx, "a.txt", "theirs\n")

        let result = try await fx.service.syncBase(id: id)
        guard case .conflicts(let moved, let files, let saved) = result else {
            Issue.record("got \(result)")
            return
        }
        #expect(files == ["a.txt"] && moved.overlapping == ["a.txt"] && saved != nil)
        let text = try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(text.contains("<<<<<<<") && text.contains("mine") && text.contains("theirs"))
        let mergeHead = try await fx.git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: worktree)
        #expect(mergeHead.succeeded, "the merge is left in progress")

        let event = try #require(try fx.events(id).last { $0.kind.rawValue == "base.synced" })
        #expect(event.data["result"]?.stringValue == "conflicts")
        #expect(event.data["conflicts"] == .array(["a.txt"]))

        // Another sync meets the unfinished merge and says so, instead of stacking a second one on it.
        await #expect(throws: ThreadServiceError.self) { _ = try await fx.service.syncBase(id: id) }
    }

    @Test func anEndedThreadAThreadWithoutAWorktreeAndALiveRunnerAreRefused() async throws {
        let fx = try await RunnerFixture()
        _ = try await addOrigin(fx)
        let bare = try await fx.service.newThread(name: "bare", base: "main")
        await #expect(throws: ThreadServiceError.self) { _ = try await fx.service.syncBase(id: bare) }
        #expect(try await fx.service.baseMovement(id: bare, fetch: false) == nil, "no worktree, nothing to compare")

        try await fx.service.abandon(id: bare)  // frees the one slot
        let (id, _) = try await thread(fx)
        try await fx.service.abandon(id: id)
        await #expect(throws: ThreadServiceError.threadEnded("abandoned")) { _ = try await fx.service.syncBase(id: id) }
    }

    @Test func aReadOnlyLookDoesNotTouchTheNetworkAndSeesWhatWasFetchedBefore() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await thread(fx)
        try write(worktree, "a.txt", "one\nmine\n")
        try await landOnMain(fx, "b.txt", "theirs\n")
        // The push updated the project's own refs/remotes/origin/main, which is what an unfetched look reads.
        let seen = try #require(try await fx.service.baseMovement(id: id, fetch: false))
        #expect(seen.behind == 1 && seen.overlapping.isEmpty)
        // A look with a fetch that fails is an error, not a stale answer passed off as fresh.
        _ = try await fx.git.run(["remote", "set-url", "origin", fx.repo.appendingPathComponent("no-such.git").path], in: fx.repo)
        do {
            _ = try await fx.service.baseMovement(id: id, fetch: true)
            Issue.record("expected the failed fetch to throw")
        } catch let error as ThreadServiceError {
            guard case .syncFailed = error else {
                Issue.record("a failed fetch is a failure, not a refusal: \(error)")
                return
            }
        }
    }

    @Test func aWorktreeOnAnotherBranchIsRefusedAndNothingIsCommitted() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await thread(fx)
        try write(worktree, "a.txt", "one\nmine\n")
        try await landOnMain(fx, "b.txt", "theirs\n")
        _ = try await fx.git.run(["switch", "-q", "-c", "elsewhere"], in: worktree)
        let before = try await fx.git.run(["rev-parse", "HEAD"], in: worktree).stdout

        do {
            _ = try await fx.service.syncBase(id: id)
            Issue.record("expected a refusal")
        } catch let error as ThreadServiceError {
            guard case .syncRefused(let why) = error else {
                Issue.record("got \(error)")
                return
            }
            #expect(why.contains("elsewhere") && why.contains("workbench/\(id)"))
        }
        #expect(try await fx.git.run(["rev-parse", "HEAD"], in: worktree).stdout == before, "nothing was committed")
        #expect(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8) == "one\nmine\n")
        #expect(!(try kinds(fx, id).contains("base.synced")))
    }

    @Test func aRunHoldingTheThreadRefusesTheSyncBeforeAnythingChanges() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await thread(fx)
        try write(worktree, "a.txt", "one\nmine\n")
        try await landOnMain(fx, "b.txt", "theirs\n")
        // A run holds the thread's log (as `workbench run` does for its whole length), with its runner file naming this process.
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        let member = ProcessTree.member(for: getpid())
        let info: [String: Any] = [
            "pid": getpid(), "started_seconds": member?.startSeconds ?? 0, "started_micros": member?.startMicros ?? 0,
        ]
        try JSONSerialization.data(withJSONObject: info).write(to: fx.project.runnerURL(id))

        await #expect(throws: ThreadServiceError.self) { _ = try await fx.service.syncBase(id: id) }
        await log.close()
        #expect(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8) == "one\nmine\n")
        let status = try await fx.git.run(["status", "--porcelain"], in: worktree)
        #expect(status.stdout.contains("a.txt"), "the work was not committed under the run's feet")
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("b.txt").path), "nothing was merged")
    }

    @Test func aTurnADeadRunnerLeftOpenIsClosedBeforeTheMerge() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await thread(fx)
        try write(worktree, "a.txt", "one\nmine\n")
        try await landOnMain(fx, "b.txt", "theirs\n")
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.turnStarted, turn: 1, data: [:])
        await log.close()  // the runner is gone: a turn is open and nothing holds the thread

        let result = try await fx.service.syncBase(id: id)
        guard case .merged = result else {
            Issue.record("got \(result)")
            return
        }
        let kinds = try kinds(fx, id)
        #expect(kinds.filter { $0 == "turn.started" }.count == 1 && kinds.filter { $0 == "turn.ended" }.count == 1)
        #expect(kinds.last == "base.synced", "the turn ended first, then the sync: \(kinds)")
    }

    @Test func theNoteStartsATurnThatSeesTheConflictedFile() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())  // turn 1: the thread has a worktree and a turn behind it
        _ = try await addOrigin(fx)
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try write(worktree, "a.txt", "mine\n")
        try await landOnMain(fx, "a.txt", "theirs\n")

        let result = try await fx.service.syncBase(id: id)
        guard case .conflicts = result else {
            Issue.record("got \(result)")
            return
        }
        let note = try #require(SyncPrompt.note(for: result))
        var options = fx.options()
        options.feedback = note
        let report = try await fx.runner(id).run(options)

        #expect(report.turn == 2)
        let prompt = try String(contentsOf: fx.project.promptURL(id, turn: 2), encoding: .utf8)
        #expect(prompt.contains("a.txt") && prompt.contains(note), "the turn starts from what the sync found")
        let kinds = try kinds(fx, id)
        #expect(kinds.filter { $0 == "turn.started" }.count == 2 && kinds.filter { $0 == "turn.ended" }.count == 2)
    }

    @Test func theReviewReportsTheMovementWithoutFetchingAndOnlyForAnActiveThread() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await thread(fx)
        try write(worktree, "a.txt", "one\nmine\n")
        try await landOnMain(fx, "b.txt", "theirs\n")

        let loader = ReviewLoader(project: fx.project, git: fx.git)
        let moved = try #require(await loader.load(id: id).baseMovement)
        #expect(moved.behind == 1 && moved.overlapping.isEmpty)

        try await fx.service.abandon(id: id)
        #expect(await loader.load(id: id).baseMovement == nil, "an ended thread has nothing to bring the base into")
    }
}
