import Foundation
import Testing

@testable import WorkbenchCore

private let skillPath = ".claude/skills/verify/SKILL.md"
private let skillText = "# Verify\n\nBuild the app and press the button. SKILL-SENTINEL\n"

/// A thread with one finished turn whose base commit holds the verifier's skill.
struct VerifierFixture {
    let fx: RunnerFixture
    let id: String
    let config: Config

    init(
        verifier: String = "", skill: String? = skillText, check: String? = nil, runTurn: Bool = true, root: String = "",
        run: String = "", files: [String: String] = [:]
    ) async throws {
        let table = """
            [verifier]
            skill = "\(skillPath)"
            model = "sonnet"
            tools = ["Read", "Bash(scripts/snap.sh:*)"]
            \(verifier)
            """
        // The root keys of the fixture come first, so the verifier table goes last: the fixture appends `[tools]`
        // after `extraConfig`, which would end it, so it is written again after.
        fx = try await RunnerFixture(extraConfig: (check.map { "check_command = \"\($0)\"\n" } ?? "") + root)
        var text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        text += "\n" + table + "\n" + run + "\n"
        try text.write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        // Committed before the thread exists, so they are in its worktree; executable, like a project's scripts.
        for (path, body) in files {
            let url = fx.repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        if !files.isEmpty {
            _ = try await fx.git.run(["add", "-A"], in: fx.repo)
            _ = try await fx.git.run(["commit", "-q", "-m", "scripts"], in: fx.repo)
        }
        if let skill {
            let url = fx.repo.appendingPathComponent(skillPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try skill.write(to: url, atomically: true, encoding: .utf8)
            _ = try await fx.git.run(["add", "-A"], in: fx.repo)
            _ = try await fx.git.run(["commit", "-q", "-m", "skill"], in: fx.repo)
        }
        id = try await fx.approvedThread()
        config = try Config.load(from: fx.project.configURL)
        if runTurn { _ = try await fx.runner(id).run(fx.options()) }
    }

    var worktree: URL { WorktreeManager(repoRoot: fx.repo, git: fx.git).path(for: id) }

    func environment(_ directives: String...) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
            "FAKE_CLAUDE": directives.joined(separator: ","),
            "GITHUB_TOKEN": "ghp_not_for_the_model", "SSH_AUTH_SOCK": "/tmp/agent.sock",
        ]
    }

    func verify(
        _ directives: String..., again: Bool = false, timeout: TimeInterval = 20, grace: TimeInterval = 2,
        attach: @Sendable (ProcessRun) -> Void = { _ in }
    ) async throws -> VerifierReport {
        try await fx.service.verifier(
            id: id, config: config, again: again, environment: environment(directives.joined(separator: ",")),
            timeout: timeout, killGrace: grace, attach: attach)
    }

    func verifierEvents() throws -> [Event] {
        try fx.events(id).filter { $0.kind == .verifierStarted || $0.kind == .verifierEnded }
    }

    /// Every start has exactly one end, in order.
    func expectPaired(_ expected: Int, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let events = try verifierEvents()
        let want = Array(repeating: ["verifier.started", "verifier.ended"], count: expected).flatMap { $0 }
        #expect(events.map(\.kind.rawValue) == want, "\(events.map(\.kind.rawValue))", sourceLocation: sourceLocation)
        #expect(try fx.contents(id).isHealthy, sourceLocation: sourceLocation)
    }
}

private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !alive(pid) { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return !alive(pid)
}

private func pid(in path: String) throws -> pid_t {
    try #require(pid_t(try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
}

@Suite(.processGate) struct VerifierRunTests {
    @Test func theRunIsAskedForEverythingTheProjectConfiguredAndNothingElse() async throws {
        let v = try await VerifierFixture()
        let dump = FakeClaude.scratch("verifier-dump")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        let report = try await v.verify("dump=\(dump),proof=shot.png")
        #expect(report.ok)

        let info = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dump))) as? [String: Any])
        let argv = try #require(info["argv"] as? [String])
        func value(after flag: String) -> String? { argv.firstIndex(of: flag).map { argv[$0 + 1] } }
        #expect(value(after: "--model") == "sonnet")
        #expect(value(after: "--output-format") == "json")
        #expect(value(after: "--max-budget-usd") == "1")
        for flag in ["-p", "--safe-mode", "--restricted", "--disable-slash-commands"] { #expect(argv.contains(flag), "\(flag)") }
        // Exactly the configured tools: available by name, allowed by pattern, then the prompt after `--`.
        let tools = try #require(argv.firstIndex(of: "--tools"))
        #expect(Array(argv[(tools + 1)...].prefix(2)) == ["Read", "Bash"])
        let allowed = try #require(argv.firstIndex(of: "--allowedTools"))
        #expect(Array(argv[(allowed + 1)...].prefix(2)) == ["Read", "Bash(scripts/snap.sh:*)"])
        #expect(argv[allowed + 3] == "--disallowedTools" || argv[allowed + 3] == "--")
        #expect(!argv.contains("--resume"))
        // The proof folder is readable to the run's file tools, which are confined to the worktree otherwise.
        #expect(value(after: "--add-dir") == v.fx.project.proofDirectory(v.id, turn: 1).path)

        // The prompt: the skill text, the goal's criteria and the three variables.
        let prompt = try #require(argv.last)
        let proof = v.fx.project.proofDirectory(v.id, turn: 1).path
        for needle in [
            "SKILL-SENTINEL", skillPath, "a.txt contains the word hello.", "WORKBENCH_PROOF_DIR=\(proof)",
            "WORKBENCH_THREAD=\(v.id)", "WORKBENCH_GOAL=\(v.fx.project.goalURL(v.id).path)",
        ] { #expect(prompt.contains(needle), "\(needle)") }

        // The environment: the allowlist and the three variables, no credentials; the working directory is the worktree.
        let env = try #require(info["env"] as? [String: String])
        #expect(env["WORKBENCH_PROOF_DIR"] == proof && env["WORKBENCH_THREAD"] == v.id)
        #expect(env["WORKBENCH_GOAL"] == v.fx.project.goalURL(v.id).path)
        #expect(env["GITHUB_TOKEN"] == nil && env["SSH_AUTH_SOCK"] == nil)
        let cwd = try #require(info["cwd"] as? String)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == v.worktree.resolvingSymlinksInPath().path)
        #expect(info["stdin_eof"] as? Bool == true)
        #expect(info["pgid"] as? Int != Int(getpgrp()), "its own process group")
    }

    @Test func startedIsLoggedBeforeTheSpendAndWithoutThePrompt() async throws {
        let v = try await VerifierFixture()
        let report = try await v.verify("proof=shot.png")
        #expect(report.ok && report.turn == 1)
        try v.expectPaired(1)
        let events = try v.verifierEvents()
        let started = events[0].data
        #expect(started["skill"]?.stringValue == skillPath)
        #expect(started["sha256"]?.stringValue?.count == 64 && started["bytes"]?.intValue == skillText.utf8.count - 1)
        guard case .array(let argv)? = started["argv"] else { Issue.record("argv missing"); return }
        let shown = argv.compactMap(\.stringValue)
        #expect(!shown.contains("--") && !shown.joined(separator: " ").contains("SKILL-SENTINEL"))
        #expect(events[0].turn == 1 && events[1].turn == 1)

        let ended = events[1].data
        #expect(ended["ok"] == true && ended["cost_usd"] == .double(0.001) && ended["duration_ms"]?.intValue != nil)
        #expect(ended["report"]?.stringValue?.hasPrefix("fake claude:") == true)
        guard case .array(let files)? = ended["files"] else { Issue.record("files missing"); return }
        #expect(files.count == 1 && files[0]["name"]?.stringValue == "shot.png")
        #expect(files[0]["sha256"]?.stringValue?.count == 64)
        #expect(report.files.map(\.name) == ["shot.png"])
    }

    @Test func onlyFilesItAddedOrChangedAreListed() async throws {
        let v = try await VerifierFixture()
        let dir = v.fx.project.proofDirectory(v.id, turn: 1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "from the verify step".write(to: dir.appendingPathComponent("old.png"), atomically: true, encoding: .utf8)
        let report = try await v.verify("proof=new.png")
        #expect(report.files.map(\.name) == ["new.png"])
    }

    // MARK: Refusals

    @Test func aProjectThatTurnedTheVerifierOffIsRefused() async throws {
        let fx = try await RunnerFixture(extraConfig: "[verifier]\nenabled = false")
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let config = try Config.load(from: fx.project.configURL)
        await #expect(throws: VerifierRefusal.notConfigured) { try await fx.service.verifier(id: id, config: config) }
    }

    @Test func aThreadWithNoTurnIsRefused() async throws {
        let fx = try await RunnerFixture(extraConfig: "")
        var text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        text += "\n[verifier]\nskill = \"\(skillPath)\"\n"
        try text.write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let id = try await fx.approvedThread()
        let config = try Config.load(from: fx.project.configURL)
        await #expect(throws: VerifierRefusal.noTurn) { try await fx.service.verifier(id: id, config: config) }
    }

    @Test func aSkillMissingAtTheBaseIsRefusedWithThePathAndSpendsNothing() async throws {
        let v = try await VerifierFixture(skill: nil)
        do {
            _ = try await v.verify()
            Issue.record("expected a refusal")
        } catch let refusal as VerifierRefusal {
            #expect("\(refusal)".contains(skillPath), "\(refusal)")
        }
        #expect(try v.verifierEvents().isEmpty)
    }

    @Test func aSkillEditedAfterTheBaseIsNotWhatTheModelIsTold() async throws {
        let v = try await VerifierFixture()
        try "EDITED-BY-THE-RUN".write(
            to: v.worktree.appendingPathComponent(skillPath), atomically: true, encoding: .utf8)
        let dump = FakeClaude.scratch("verifier-edited")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        _ = try await v.verify("dump=\(dump)")
        let text = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(text.contains("SKILL-SENTINEL") && !text.contains("EDITED-BY-THE-RUN"))
    }

    @Test func aSecondRunNeedsAgainOnlyAfterAnOkOne() async throws {
        let v = try await VerifierFixture()
        let failed = try await v.verify("error-result")
        #expect(!failed.ok)
        let first = try await v.verify()  // a failed attempt does not count as having verified the turn
        #expect(first.ok)
        await #expect(throws: VerifierRefusal.alreadyVerified(turn: 1)) { try await v.verify() }
        let again = try await v.verify(again: true)
        #expect(again.ok)
        try v.expectPaired(3)
    }

    @Test func aThreadWhoseWorktreeIsGoneIsRefused() async throws {
        let v = try await VerifierFixture()
        try await WorktreeManager(repoRoot: v.fx.repo, git: v.fx.git).remove(
            threadID: v.id, force: true, deleteBranch: false)
        await #expect(throws: VerifierRefusal.noWorktree) { try await v.verify() }
    }

    @Test func aMissingClaudeIsARefusalAndSpendsNothing() async throws {
        let v = try await VerifierFixture(verifier: "")
        var broken = v.config
        broken.claudePath = "/no/such/claude"
        await #expect(throws: VerifierRefusal.claudeNotFound("/no/such/claude")) {
            try await v.fx.service.verifier(id: v.id, config: broken, environment: v.environment())
        }
        #expect(try v.verifierEvents().isEmpty)
    }

    // MARK: Every ending is one verifier.ended

    @Test(arguments: [
        ("crash-after=1", "status 70"),
        ("die-after=1", "signal 9"),
        ("error-result", "claude reported an error"),
        ("budget-stop", "stopped at the budget ($1)"),
    ])
    func aRunThatFailsEndsOnce(directive: String, reason: String) async throws {
        let v = try await VerifierFixture()
        let report = try await v.verify(directive)
        #expect(!report.ok && report.reason?.contains(reason) == true, "\(report.reason ?? "nil")")
        try v.expectPaired(1)
        let ended = try #require(try v.verifierEvents().last)
        #expect(ended.data["ok"] == false && ended.data["reason"]?.stringValue?.contains(reason) == true)
        if directive == "budget-stop" { #expect(report.costUSD == 0.5) }
    }

    @Test func aHungRunIsEndedAtTheTimeout() async throws {
        let v = try await VerifierFixture()
        let report = try await v.verify("hang-after=1", timeout: 1)
        #expect(!report.ok && report.reason?.contains("did not finish within 1s") == true, "\(report.reason ?? "nil")")
        try v.expectPaired(1)
    }

    @Test func aRunThatIgnoresSIGTERMIsKilledAndStillEnded() async throws {
        let v = try await VerifierFixture()
        let report = try await v.verify("hang-after=1,ignore-term", timeout: 1, grace: 0.3)
        #expect(!report.ok)
        try v.expectPaired(1)
        #expect(try v.verifierEvents().last?.data["escalated_to_kill"] == true)
    }

    @Test func aStopDuringTheRunEndsItOnce() async throws {
        let v = try await VerifierFixture()
        let holder = StopHolder()
        let task = Task { try await v.verify("hang-after=1", timeout: 30, attach: { holder.attach($0) }) }
        #expect(await holder.waitForRun())
        holder.stop()
        let report = try await task.value
        #expect(!report.ok && report.reason == "the verifier was stopped")
        try v.expectPaired(1)
    }

    @Test func aStopThatArrivesBeforeTheRunStartedStillEndsItOnce() async throws {
        let v = try await VerifierFixture()
        // The stop is asked for before there is a process; the first one to attach is stopped at once.
        let holder = StopHolder()
        holder.stop()
        let report = try await v.verify("hang-after=1", timeout: 30, attach: { holder.attach($0) })
        #expect(!report.ok && report.reason == "the verifier was stopped")
        try v.expectPaired(1)
    }

    // MARK: What it leaves behind is swept

    @Test func aToolChildItLeftIsEndedWithTheRun() async throws {
        let v = try await VerifierFixture()
        let pidFile = FakeClaude.scratch("verifier-gc")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        _ = try await v.verify("grandchild=\(pidFile)")
        let child = try pid(in: pidFile)
        #expect(await waitUntilGone(child), "the grandchild is still running")
    }

    @Test func anAppItStartedInAnotherSessionIsEndedWithTheRun() async throws {
        let v = try await VerifierFixture()
        let pidFile = FakeClaude.scratch("verifier-detached")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let report = try await v.verify("detached=\(pidFile)")
        let app = try pid(in: pidFile)
        defer { kill(app, SIGKILL) }
        #expect(report.ok)
        #expect(await waitUntilGone(app), "the detached process is still running")
        // Ended by the run's own sweep of what it saw, or by the sweep of orphans in the worktree: either is the promise.
        let ended = try #require(try v.verifierEvents().last?.data)
        let swept = (ended["swept_orphans"]?.intValue ?? 0) + (ended["swept_processes"]?.intValue ?? 0)
        #expect(swept >= 1, "\(ended)")
    }

    @Test func anAppAKilledVerifierLeftIsEndedBeforeTheNextOne() async throws {
        let v = try await VerifierFixture()
        let pidFile = FakeClaude.scratch("verifier-left")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        // A process in a session of its own, re-parented to launchd, whose working directory is the worktree: what a
        // killed verifier leaves behind (an app opened outside the run's process group).
        let script = "use POSIX; my $p = fork(); if ($p == 0) { POSIX::setsid(); exec '/bin/sleep', '300' } "
            + "open(F, '>', $ARGV[0]); print F $p; close F;"
        // Started outside the process layer on purpose: its sweep of a child's descendants would otherwise kill the
        // leftover on a slow machine, before the test has made it.
        let perl = Process()
        perl.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        perl.arguments = ["-e", script, pidFile]
        perl.currentDirectoryURL = v.worktree
        perl.environment = ["PATH": "/usr/bin:/bin"]
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            perl.terminationHandler = { _ in done.resume() }
            do { try perl.run() } catch { done.resume() }
        }
        let left = try pid(in: pidFile)
        defer { kill(left, SIGKILL) }
        #expect(alive(left))
        _ = try await v.verify()
        #expect(await waitUntilGone(left), "the leftover is still running")
    }

    // MARK: Busy, and the log held

    @Test func whileTheLogIsHeldASecondVerifierIsBusy() async throws {
        let v = try await VerifierFixture()
        let held = try EventLogWriter.open(at: v.fx.project.eventsURL(v.id))
        defer { Task { await held.close() } }
        await #expect(throws: VerifierRefusal.busy) { try await v.verify() }
    }

    @Test func aLiveRunnerRefusesAVerifier() async throws {
        let v = try await VerifierFixture()
        let member = ProcessTree.member(for: getpid())
        let info: [String: Any] = [
            "pid": getpid(), "started_seconds": member?.startSeconds ?? 0, "started_micros": member?.startMicros ?? 0,
        ]
        try JSONSerialization.data(withJSONObject: info).write(to: v.fx.project.runnerURL(v.id))
        defer { try? FileManager.default.removeItem(at: v.fx.project.runnerURL(v.id)) }
        await #expect(throws: ThreadServiceError.self) { try await v.verify() }
    }

    @Test func theThreadIsHeldWhileItRunsAndFreeAfter() async throws {
        let v = try await VerifierFixture()
        let holder = StopHolder()
        let task = Task { try await v.verify("hang-after=1", timeout: 30, attach: { holder.attach($0) }) }
        #expect(await holder.waitForRun())
        // Held: a second verifier, and a judge, are refused.
        await #expect(throws: (any Error).self) { try await v.verify() }
        holder.stop()
        _ = try await task.value
        #expect(!FileManager.default.fileExists(atPath: v.fx.project.runnerURL(v.id).path))
        let again = try await v.verify()
        #expect(again.ok)
    }

    // MARK: Restart recovery

    @Test func aVerifierLeftOpenByADeadProcessIsClosedByTheNextCommand() async throws {
        let v = try await VerifierFixture()
        let log = try EventLogWriter.open(at: v.fx.project.eventsURL(v.id))
        try await log.append(.verifierStarted, turn: 1, data: ["argv": ["claude"]])
        await log.close()

        let report = try await v.verify()
        #expect(report.ok)
        let events = try v.verifierEvents()
        #expect(events.map(\.kind.rawValue) == ["verifier.started", "verifier.ended", "verifier.started", "verifier.ended"])
        #expect(events[1].data["synthetic"] == true && events[1].data["reason"]?.stringValue == "interrupted")
        #expect(events[1].turn == 1)
        #expect(try v.fx.contents(v.id).isHealthy)
    }

    @Test func aRunnerStartingOverAnOpenVerifierClosesIt() async throws {
        let v = try await VerifierFixture(verifier: "enabled = false")
        let log = try EventLogWriter.open(at: v.fx.project.eventsURL(v.id))
        try await log.append(.verifierStarted, turn: 1, data: ["argv": ["claude"]])
        await log.close()
        _ = try await v.fx.runner(v.id).run(v.fx.options("write=a.txt", feedback: "once more"))
        let kinds = try v.verifierEvents().map(\.kind.rawValue)
        #expect(kinds == ["verifier.started", "verifier.ended"])
        #expect(try v.fx.contents(v.id).isHealthy)
    }
}

/// A process to stop from the test, kept if the stop arrives first.
private final class StopHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var run: ProcessRun?
    private var stopRequested = false

    func attach(_ new: ProcessRun) {
        lock.lock()
        run = new
        let stop = stopRequested
        lock.unlock()
        if stop { new.stop() }
    }

    func stop() {
        lock.lock()
        stopRequested = true
        let current = run
        lock.unlock()
        current?.stop()
    }

    private var hasRun: Bool { lock.withLock { run != nil } }

    func waitForRun() async -> Bool {
        let deadline = Date().addingTimeInterval(Patience.limit)
        while Date() < deadline {
            if hasRun { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}

@Suite(.processGate) struct VerifierAnswerTests {
    private func answer(_ result: String, error: Bool = false) -> String {
        let escaped = result.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        return #"{"type":"result","is_error":\#(error),"result":"\#(escaped)","total_cost_usd":0.01}"#
    }

    @Test(arguments: ["", " ", "\n\n", " \t\n "])
    func anEmptyAnswerIsNotASuccess(result: String) {
        let parsed = Verifier.parse(output: answer(result), budget: 1)
        #expect(parsed.text == nil && parsed.failure == "the answer was empty" && parsed.costUSD == 0.01)
    }

    @Test func aWordIsAnAnswer() {
        let parsed = Verifier.parse(output: answer("c1: holds"), budget: 1)
        #expect(parsed.text == "c1: holds" && parsed.failure == nil)
    }

    @Test func aLongReportIsCutAtALineWithAMarkerAndStaysWithinTheLimit() {
        let lines = (0..<2000).map { "line \($0) of the report" }.joined(separator: "\n")
        let bounded = Verifier.bounded(lines)
        #expect(bounded.utf8.count <= Verifier.reportLimit)
        #expect(bounded.hasSuffix("[report cut at \(Verifier.reportLimit) bytes]"))
        #expect(bounded.hasPrefix("line 0 of the report\n"))
        #expect(Verifier.bounded("short") == "short")
    }

    @Test func aHugeReportEndsUpBoundedInTheLog() async throws {
        let v = try await VerifierFixture()
        let file = FakeClaude.scratch("verifier-answer")
        defer { try? FileManager.default.removeItem(atPath: file) }
        try (0..<5000).map { "row \($0): holds" }.joined(separator: "\n").write(
            toFile: file, atomically: true, encoding: .utf8)
        let report = try await v.verify("answer=\(file)")
        #expect(report.ok && report.report.utf8.count <= Verifier.reportLimit)
        let stored = try #require(try v.verifierEvents().last?.data["report"]?.stringValue)
        #expect(stored.utf8.count <= Verifier.reportLimit && stored.hasSuffix("bytes]"))
    }

    @Test func anEmptyAnswerFromTheRunIsRecordedAsNotOkAndDoesNotCountAsVerified() async throws {
        let v = try await VerifierFixture()
        let file = FakeClaude.scratch("verifier-empty")
        defer { try? FileManager.default.removeItem(atPath: file) }
        try "  \n".write(toFile: file, atomically: true, encoding: .utf8)
        let report = try await v.verify("answer=\(file)")
        #expect(!report.ok && report.reason == "the answer was empty")
        let again = try await v.verify()  // not blocked by --again: the first did not verify the turn
        #expect(again.ok)
    }
}
