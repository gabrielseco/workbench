import Foundation
import Testing

@testable import WorkbenchCore

// MARK: fixture

func isolatedGit(sourceLocation: SourceLocation = #_sourceLocation) throws -> GitRunner {
    expectProcessGate("isolatedGit()", sourceLocation: sourceLocation)
    return try GitRunner.discover(
        extraEnvironment: [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
        ])
}

/// A scratch repository with a `.workbench/config.toml` that points at the fake claude.
///
/// Built and used under `@Suite(.processGate)`, so the test's waits start when its processes can run.
struct RunnerFixture {
    let repo: URL
    let project: Project
    let git: GitRunner
    let service: ThreadService

    init(extraConfig: String = "", sourceLocation: SourceLocation = #_sourceLocation) async throws {
        expectProcessGate("RunnerFixture", sourceLocation: sourceLocation)
        // The repo sits in a directory of its own: the fakes tests put beside it (`gh-*`, `codex-*`, `origin-*`)
        // go there too and are removed with the run, instead of piling up in the temporary directory.
        let base = Scratch.url("run").appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        repo = base.resolvingSymlinksInPath()
        git = try isolatedGit()
        for args in [["init", "-q", "-b", "main"], ["add", "-A"]] where args[0] == "init" {
            _ = try await git.run(args, in: repo)
        }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "-A"], in: repo)
        _ = try await git.run(["commit", "-q", "-m", "first"], in: repo)

        project = Project(root: repo)
        try FileManager.default.createDirectory(at: project.workbenchDirectory, withIntermediateDirectories: true)
        let config = """
            claude_path = "\(FakeClaude.executable.path)"
            default_budget_usd = 1.00
            env_pass = ["FAKE_CLAUDE"]
            \(extraConfig)

            [tools]
            available = ["Read", "Edit", "Bash"]
            allowed = ["Read", "Edit"]
            """
        try config.write(to: project.configURL, atomically: true, encoding: .utf8)
        service = ThreadService(project: project, git: git)
    }

    /// A thread with a filled-in, approved goal.
    func approvedThread(_ name: String = "work", base: String = "main") async throws -> String {
        let id = try await service.newThread(name: name, base: base)
        let url = project.goalURL(id)
        var text = try String(contentsOf: url, encoding: .utf8)
        let fills = [
            ("TODO(workbench): say what should change, in a few sentences.", "Add a greeting to a.txt."),
            ("TODO(workbench): something that can be checked.", "a.txt contains the word hello."),
            ("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "cat a.txt"),
        ]
        for (placeholder, value) in fills { text = text.replacingOccurrences(of: placeholder, with: value) }
        text = text.replacingOccurrences(of: "TODO(workbench): what must not change.", with: "Do not touch other files.")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try await service.approve(id: id)
        return id
    }

    func runner(_ id: String, notices: NoticeBox? = nil) -> ThreadRunner {
        ThreadRunner(project: project, threadID: id, git: git) { notice in notices?.add(notice) }
    }

    func options(
        _ directives: String..., feedback: String? = nil, timeout: TimeInterval = 20, grace: TimeInterval = 5
    ) -> RunOptions {
        var o = RunOptions(feedback: feedback)
        o.timeoutOverride = timeout
        o.killGrace = grace
        o.parentEnvironment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
            "FAKE_CLAUDE": directives.joined(separator: ","),
            "SSH_AUTH_SOCK": "/tmp/agent.sock", "GITHUB_TOKEN": "ghp_not_for_the_model",
        ]
        return o
    }

    func events(_ id: String) throws -> [Event] { try EventLogReader.read(at: project.eventsURL(id)).events }

    func contents(_ id: String) throws -> EventLogContents { try EventLogReader.read(at: project.eventsURL(id)) }

    func kinds(_ id: String) throws -> [String] { try events(id).map(\.kind.rawValue) }
}

final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RunNotice] = []
    func add(_ n: RunNotice) { lock.withLock { items.append(n) } }
    var all: [RunNotice] { lock.withLock { items } }
}

func ended(_ events: [Event]) -> [Event] { events.filter { $0.kind == .turnEnded } }

// MARK: the loop

@Suite(.processGate) struct RunnerTests {
    @Test func aFullTurnIsRecordedAndLeavesAWorktree() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let notices = NoticeBox()
        let report = try await fx.runner(id, notices: notices).run(fx.options("stream-events=2"))

        #expect(report.result == .succeeded)
        #expect(report.turn == 1)
        #expect(report.costUSD == 0.001)
        #expect(report.summary?.hasPrefix("fake claude:") == true)

        let contents = try fx.contents(id)
        #expect(contents.isHealthy)
        #expect(contents.openTurn == nil)
        let kinds = try fx.kinds(id)
        #expect(
            kinds.prefix(5)
                == ["thread.created", "goal.saved", "goal.approved", "worktree.created", "turn.started"])
        #expect(kinds.last == "turn.ended")
        #expect(kinds.filter { $0 == "turn.ended" }.count == 1)
        #expect(kinds.filter { $0 == "claude" }.count == 5)  // init, 2 stream events, assistant, result

        let started = try #require(contents.events.first { $0.kind == .turnStarted })
        #expect(started.data["resume"] == false)
        #expect(started.data["pid"]?.intValue != nil)
        guard case .array(let argv)? = started.data["argv"] else {
            Issue.record("argv missing")
            return
        }
        let shown = argv.compactMap(\.stringValue)
        #expect(shown.contains("--restricted"))
        #expect(shown.contains("--session-id"))
        #expect(!shown.contains("--"), "the prompt is kept out of the log")
        #expect(!shown.joined(separator: " ").contains("Add a greeting"))

        let prompt = try String(contentsOf: fx.project.promptURL(id, turn: 1), encoding: .utf8)
        #expect(prompt.contains("Add a greeting to a.txt."))
        #expect(prompt.contains("[c1] a.txt contains the word hello."))
        #expect(prompt.contains("Do not touch other files."))

        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("a.txt").path))
        #expect(fx.contentsOfRunnerFile(id) == nil, "runner.json is removed when the run ends")
        #expect(ThreadStore(project: fx.project).session(of: id)?.confirmed == true)
    }

    @Test func theChildRunsInTheWorktreeWithTheFixedToolSet() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let dump = FakeClaude.scratch("dump.json")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        _ = try await fx.runner(id).run(fx.options("dump=\(dump)"))

        let info = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: dump))) as? [String: Any])
        let cwd = URL(fileURLWithPath: try #require(info["cwd"] as? String)).resolvingSymlinksInPath().path
        #expect(cwd == fx.project.worktreesDirectory.appendingPathComponent(id).path)
        let argv = try #require(info["argv"] as? [String])
        #expect(argv.contains("--restricted"))
        #expect(argv.contains("--permission-prompts"))
        let env = try #require(info["env"] as? [String: String])
        #expect(env["FAKE_CLAUDE"] != nil)
        #expect(env["SSH_AUTH_SOCK"] == nil, "credentials are not passed on")
        #expect(env["GITHUB_TOKEN"] == nil)
        #expect(env["HOME"] != nil, "HOME is on the fixed allowlist")
        #expect(info["stdin_eof"] as? Bool == true)
    }

    // MARK: gates

    @Test func aDraftGoalDoesNotRun() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.service.newThread(name: "draft", base: "main")
        await #expect(throws: RunnerError.self) { _ = try await fx.runner(id).run(fx.options()) }
    }

    @Test func editingAnApprovedGoalMakesRunRefuseUntilReapproved() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let url = fx.project.goalURL(id)
        let edited = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "Add a greeting to a.txt.", with: "Delete everything.")
        try edited.write(to: url, atomically: true, encoding: .utf8)

        await #expect(throws: RunnerError.goalNotApproved(.stale)) {
            _ = try await fx.runner(id).run(fx.options())
        }
        #expect(try fx.kinds(id).filter { $0 == "turn.started" }.isEmpty, "nothing ran")

        try await fx.service.approve(id: id)
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.result == .succeeded)
    }

    @Test func aSecondThreadIsRefusedNamingTheActiveOne() async throws {
        let fx = try await RunnerFixture()
        let first = try await fx.approvedThread("one")
        do {
            _ = try await fx.service.newThread(name: "two", base: "main")
            Issue.record("expected the single-thread guard")
        } catch let error as ThreadStoreError {
            #expect(error == .activeThreadExists(first))
            #expect(error.description.contains(first))
        }
    }

    @Test func abandoningFreesTheSlotAndKeepsTheBranch() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread("one")
        _ = try await fx.runner(id).run(fx.options())
        try await fx.service.abandon(id: id)

        let state = ThreadStore(project: fx.project).state(of: id)
        #expect(state.decision == "abandoned")
        #expect(!FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.appendingPathComponent(id).path))
        let branch = try await fx.git.run(["rev-parse", "--verify", "workbench/\(id)"], in: fx.repo)
        #expect(branch.succeeded, "the branch survives")

        let next = try await fx.service.newThread(name: "two", base: "main")
        #expect(ThreadStore(project: fx.project).activeThreadID() == next)
        await #expect(throws: RunnerError.self) { _ = try await fx.runner(id).run(fx.options()) }
    }

    @Test func aSecondRunnerOnTheSameThreadIsRefused() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let holder = try EventLogWriter.open(at: fx.project.eventsURL(id))
        await #expect(throws: RunnerError.alreadyRunning) { _ = try await fx.runner(id).run(fx.options()) }
        await holder.close()
    }

    // MARK: the failure matrix, at the runner level

    @Test(arguments: [
        (["exit=2"], RunResult.failed),
        (["crash-after=1"], .failed),
        (["die-after=2"], .failed),
        (["no-result"], .failed),
        (["invalid-line"], .succeeded),
        (["partial-tail"], .succeeded),
    ])
    func everyOutcomeIsRecordedWithExactlyOneEnd(directives: [String], expected: RunResult) async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        var options = fx.options()
        options.parentEnvironment["FAKE_CLAUDE"] = directives.joined(separator: ",")

        let report = try await fx.runner(id).run(options)
        #expect(report.result == expected, "\(directives)")

        let contents = try fx.contents(id)
        #expect(contents.isHealthy)
        #expect(contents.openTurn == nil)
        let ends = ended(contents.events)
        #expect(ends.count == 1)
        #expect(ends[0].data["result"]?.stringValue == expected.rawValue)
    }

    @Test func aHangIsTimedOutAndRecorded() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options("hang-after=1", timeout: 0.6))
        #expect(report.result == .timedOut)
        let end = try #require(ended(try fx.events(id)).first)
        #expect(end.data["cause"]?.stringValue == "timedOut")
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func stoppingEndsTheTurnAsStopped() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let ready = FakeClaude.scratch("ready")
        defer { try? FileManager.default.removeItem(atPath: ready) }
        let runner = fx.runner(id)
        let options = fx.options("ready=\(ready)", "hang-after=1")

        let task = Task { try await runner.run(options) }
        // #require: going on without it would stop a run that has not started, or write into a worktree
        // that does not exist yet.
        try #require(await pollUntil { FileManager.default.fileExists(atPath: ready) })
        await runner.stop()
        let report = try await task.value

        #expect(report.result == .stopped)
        #expect(try fx.contents(id).isHealthy)
        #expect(ended(try fx.events(id)).count == 1)
    }

    @Test func aBudgetStopIsRecordedAsBudgetExceeded() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(
            fx.options("fixture=\(FakeClaude.fixture("s5-budget.jsonl"))", "exit=1"))
        #expect(report.result == .budgetExceeded)
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func deniedToolCallsAreLoggedAndTheTurnStillEndsCleanly() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(
            fx.options("fixture=\(FakeClaude.fixture("s3-denied_unlisted.jsonl"))"))

        #expect(report.result == .succeeded)
        #expect(report.permissionDenials == 1)
        let log = try fx.events(id)
        let denialText = "Permission for this tool use was denied"
        #expect(log.contains { $0.data["message"]?["content"]?.stringValue == nil && "\($0.data)".contains(denialText) })
        #expect(ended(log)[0].data["permission_denials"]?.intValue == 1)
    }

    @Test func aHugeLineIsBoundedAndTheRunContinues() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options("flood=3000000"))

        #expect(report.result == .succeeded)
        let marker = try #require(try fx.events(id).first { $0.data["truncated"] == true })
        #expect((marker.data["original_bytes"]?.intValue ?? 0) > 3_000_000)
        let size = try FileManager.default.attributesOfItem(atPath: fx.project.eventsURL(id).path)[.size] as? Int
        #expect((size ?? .max) < 100_000, "the log did not grow by the size of the line")
    }

    @Test func invalidJsonIsLoggedRawAndTheRunContinues() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options("invalid-line"))
        #expect(report.result == .succeeded)
        #expect(try fx.events(id).contains { $0.data["invalid_json"]?.stringValue == "this is not json {" })
    }

    // MARK: recovery and sessions

    @Test func aTurnLeftOpenByADeadRunnerIsClosedAsInterruptedAndTheNextRunProceeds() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        do {
            let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
            try await log.append(.turnStarted, turn: 1, data: ["session_id": "x", "resume": false])
            try await log.appendClaudeLine(#"{"type":"system","subtype":"init"}"#, turn: 1)
            await log.close()  // the runner "dies" here
        }
        #expect(try fx.contents(id).openTurn == 1)

        let notices = NoticeBox()
        let report = try await fx.runner(id, notices: notices).run(fx.options())

        let log = try fx.events(id)
        let ends = ended(log)
        #expect(ends.count == 2)
        #expect(ends[0].data["result"]?.stringValue == "interrupted")
        #expect(ends[0].data["synthetic"] == true)
        #expect(ends[1].data["result"]?.stringValue == "succeeded")
        #expect(report.turn == 2)
        #expect(try fx.contents(id).isHealthy)
        #expect(notices.all.contains { if case .recoveredOrphanedTurn(1) = $0 { true } else { false } })
    }

    @Test func aSecondTurnResumesTheSameSessionWithFeedback() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let sessions = FakeClaude.scratch("sessions")
        defer { try? FileManager.default.removeItem(atPath: sessions) }

        let first = try await fx.runner(id).run(fx.options("sessions=\(sessions)"))
        #expect(first.result == .succeeded)

        // Without feedback there is nothing new to say.
        await #expect(throws: RunnerError.feedbackRequired) {
            _ = try await fx.runner(id).run(fx.options("sessions=\(sessions)"))
        }

        let second = try await fx.runner(id).run(
            fx.options("sessions=\(sessions)", feedback: "Also add a farewell."))
        #expect(second.result == .succeeded)
        #expect(second.turn == 2)
        #expect(second.sessionID == first.sessionID)

        let log = try fx.events(id)
        let starts = log.filter { $0.kind == .turnStarted }
        #expect(starts.map { $0.data["resume"] } == [false, true])
        #expect(log.contains { $0.kind == .threadNote && $0.data["text"]?.stringValue == "Also add a farewell." })
        let prompt = try String(contentsOf: fx.project.promptURL(id, turn: 2), encoding: .utf8)
        #expect(prompt.contains("Also add a farewell."))
        #expect(try fx.contents(id).isHealthy)
    }

    @Test func feedbackBeforeAnyTurnIsRefused() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        await #expect(throws: RunnerError.feedbackWithoutPriorTurn) {
            _ = try await fx.runner(id).run(fx.options(feedback: "hello"))
        }
    }

    @Test func anUnconfirmedSessionFallsBackToCreatingIt() async throws {
        // A first turn killed before the CLI persisted anything leaves session.json saying "not confirmed".
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let sessions = FakeClaude.scratch("sessions")
        defer { try? FileManager.default.removeItem(atPath: sessions) }
        let sessionID = UUID().uuidString.lowercased()
        try ThreadStore(project: fx.project).save(.init(sessionID: sessionID, confirmed: false), for: id)

        let report = try await fx.runner(id).run(fx.options("sessions=\(sessions)"))
        #expect(report.result == .succeeded)
        #expect(report.sessionID == sessionID)

        let log = try fx.events(id)
        let ends = ended(log).map { $0.data["result"]?.stringValue }
        #expect(ends == ["failed", "succeeded"], "resume failed at once, then the session was created")
        #expect(log.filter { $0.kind == .turnStarted }.map { $0.data["resume"] } == [true, false])
        #expect(ThreadStore(project: fx.project).session(of: id)?.confirmed == true)
    }

    @Test func aProcessOrphanedInTheWorktreeIsSweptOnTheNextRun() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        // Make the worktree exist, then leave a background process behind in it, parent gone.
        _ = try await fx.runner(id).run(fx.options())
        try await fx.service.abandon(id: id)
        let id2 = try await fx.approvedThread("two")
        let worktree = try await WorktreeManager(repoRoot: fx.repo, git: fx.git)
            .create(threadID: id2, base: "main")

        let null = open("/dev/null", O_WRONLY)
        defer { close(null) }
        let sh = try Spawner.spawn(
            executable: "/bin/sh", arguments: ["-c", "exec sleep 300 &"], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: worktree.path.path, stdout: null, stderr: null)
        var status: Int32 = 0
        waitpid(sh, &status, 0)

        var orphan: ProcessMember?
        let deadline = Date().addingTimeInterval(Patience.limit)
        while orphan == nil, Date() < deadline {
            orphan = OrphanSweeper.orphans(inside: worktree.path).first
            if orphan == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let member = try #require(orphan, "the helper process should be orphaned and found by its cwd")
        defer { kill(member.pid, SIGKILL) }

        let report = try await fx.runner(id2).run(fx.options())
        #expect(report.result == .succeeded)
        #expect(await FakeClaude.waitUntilGone(member.pid))
        #expect(try fx.kinds(id2).contains("orphans.swept"))
    }
}

// MARK: classification and formatting

@Suite(.processGate) struct ClassificationTests {
    private func exit(
        _ termination: Termination = .exited(0), cause: StopCause = .natural
    ) -> ProcessExit {
        ProcessExit(
            termination: termination, cause: cause, durationMs: 1, escalatedToKill: false, sweptProcesses: 0,
            outputTruncated: false, lastLineAfterLimit: nil, stderrTail: "", drainTimedOut: false)
    }

    /// The adapter judges the `result` line, the runner applies stop and deadline: together they are what the
    /// runner's own classification was before the adapter existed.
    private func classify(exit: ProcessExit?, result: [String: Any]?) -> RunResult {
        guard let exit else { return .failed }
        let (outcome, failure) = ClaudeDecoder.judge(exit: exit, result: result)
        return ThreadRunner.runResult(exit: exit, outcome: outcome, failure: failure)
    }

    @Test func mapsEveryCase() {
        let success: [String: Any] = ["subtype": "success", "is_error": false]
        #expect(classify(exit: exit(), result: success) == .succeeded)
        #expect(classify(exit: exit(), result: nil) == .failed)
        #expect(classify(exit: nil, result: success) == .failed)
        #expect(classify(exit: exit(.exited(1)), result: success) == .failed)
        #expect(classify(exit: exit(.signaled(9)), result: success) == .failed)
        #expect(classify(exit: exit(.lost), result: nil) == .failed)
        #expect(
            classify(exit: exit(.exited(1)), result: ["subtype": "error_max_budget_usd", "is_error": true])
                == .budgetExceeded)
        #expect(classify(exit: exit(.exited(1)), result: ["terminal_reason": "budget_exhausted"]) == .budgetExceeded)
        #expect(classify(exit: exit(.exited(143), cause: .stopped), result: success) == .stopped)
        #expect(classify(exit: exit(.signaled(15), cause: .timedOut), result: nil) == .timedOut)
        #expect(classify(exit: exit(), result: ["subtype": "error_during_execution", "is_error": true]) == .failed)
        #expect(classify(exit: exit(), result: ["subtype": "success", "is_error": true]) == .failed)
    }
}

@Suite(.processGate) struct ThreadServiceTests {
    @Test func newThreadWritesADraftThatCannotBeApprovedUntilFilledIn() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.service.newThread(name: "retry-backoff", base: "main")
        #expect(id.hasPrefix("g-"))
        #expect(id.hasSuffix("-retry-backoff"))

        let text = try String(contentsOf: fx.project.goalURL(id), encoding: .utf8)
        #expect(text.contains("base: main"))
        #expect(text.contains("budget_usd: 5"))
        let parsed = try GoalFile.parse(text)
        #expect(parsed.goal.approval == .draft)
        #expect(try fx.kinds(id) == ["thread.created", "goal.saved"])

        await #expect(throws: ThreadServiceError.goalPlaceholdersRemain) { try await fx.service.approve(id: id) }
    }

    @Test func approveIsIdempotentAndLogsOnce() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let before = try fx.kinds(id).count
        let again = try await fx.service.approve(id: id)
        #expect(again.goal.approval == .approved)
        #expect(try fx.kinds(id).count == before)
        #expect(try fx.kinds(id).filter { $0 == "goal.approved" }.count == 1)
    }

    @Test func invalidNamesAreRefused() async throws {
        let fx = try await RunnerFixture()
        for bad in ["../x", "a b", "-x", ""] {
            await #expect(throws: ThreadStoreError.invalidName(bad)) {
                _ = try await fx.service.newThread(name: bad, base: "main")
            }
        }
    }

    @Test func requestStopWithoutALiveRunnerSaysSo() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        #expect(fx.service.requestStop(id: id) == .notRunning)

        // A leftover file for a process that no longer exists is not a runner.
        let stale = #"{"pid":999999,"started_seconds":1,"started_micros":1}"#
        try stale.write(to: fx.project.runnerURL(id), atomically: true, encoding: .utf8)
        #expect(fx.service.requestStop(id: id) == .notRunning)
    }

    @Test func requestStopRefusesAPidWithTheWrongStartTime() async throws {
        // This very process, but claiming a different start time: a recycled pid must not be signalled.
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let me = try #require(ProcessTree.member(for: getpid()))
        let wrong = #"{"pid":\#(getpid()),"started_seconds":\#(me.startSeconds &+ 100),"started_micros":0}"#
        try wrong.write(to: fx.project.runnerURL(id), atomically: true, encoding: .utf8)
        #expect(fx.service.requestStop(id: id) == .notRunning)
    }
}

@Suite(.processGate) struct LogFormatterTests {
    @Test func describesTheInterestingParts() throws {
        func event(_ kind: EventKind, _ data: JSONValue, turn: Int = 1) -> Event {
            Event(seq: 7, ts: "2026-10-12T20:11:03.120Z", turn: turn, kind: kind, data: data)
        }
        let ended = LogFormatter.describe(
            event(.turnEnded, ["result": "succeeded", "cost_usd": 0.0123, "duration_ms": 4200, "permission_denials": 2]))
        #expect(ended.contains("20:11:03"))
        #expect(ended.contains("turn ended: succeeded"))
        #expect(ended.contains("$0.0123"))
        #expect(ended.contains("4s"))
        #expect(ended.contains("2 denied"))

        let tool = LogFormatter.describe(
            event(
                .claude,
                [
                    "type": "assistant",
                    "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": "git status"]]]],
                ]))
        #expect(tool.contains("tool: Bash git status"))

        #expect(LogFormatter.describe(event(.claude, ["truncated": true, "original_bytes": 5000])).contains("5000 bytes"))
        #expect(LogFormatter.describe(event(.claude, ["type": "stream_event"])).hasSuffix("claude"))
    }
}

extension RunnerFixture {
    func contentsOfRunnerFile(_ id: String) -> String? {
        try? String(contentsOf: project.runnerURL(id), encoding: .utf8)
    }
}
