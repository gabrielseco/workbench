import Foundation
import Testing

@testable import WorkbenchCore

private let criteria = "A unit is gated when its new version depends on a setting that is not enabled."

// MARK: a run with a gate

/// A `fix: pr` task with a gate, in a project with a real repository, the fake claude (answering one read-only turn after another from
/// a folder of answers) and a fake gh.
private struct Gated {
    let fx: RunnerFixture
    let task: TaskFixture
    let gh: FakeGH
    let answers: URL

    init(
        front: String = "batch: 2\ngate_rounds: 3", pending: [String] = ["ROU", "TUR", "PAN"], extraConfig: String = ""
    ) async throws {
        fx = try await RunnerFixture(extraConfig: "max_active_threads = 1\ncheck_command = \"true\"\n" + extraConfig)
        task = try TaskFixture(
            in: fx.project, front: "fix: pr\npending: pending.sh\ngate: inline\n" + front,
            body: "Bump the next countries.\n\n## Gate\n\(criteria)")
        gh = try FakeGH(in: fx)
        answers = fx.repo.deletingLastPathComponent().appendingPathComponent("answers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        try setPending(pending)
        try await task.library.approve(task.name)
    }

    func setPending(_ ids: [String]) throws {
        let list = ids.map { "{\"id\":\"\($0)\",\"title\":\"\($0) v1 -> v2\"}" }.joined(separator: ",")
        try task.script("echo '[\(list)]'")
    }

    /// The answers the fake claude gives the read-only turns, in order: the gate's, then the pull request's description.
    func answer(_ texts: String...) throws {
        try? FileManager.default.removeItem(at: answers)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        for (i, text) in texts.enumerated() {
            try text.write(to: answers.appendingPathComponent("\(i + 1).txt"), atomically: true, encoding: .utf8)
        }
    }

    static let description = #"{"title": "chore: bump countries", "summary": "Bumps them.", "decisions": [], "deviations": []}"#

    /// How many read-only turns the fake claude has answered.
    var asked: Int {
        (try? String(contentsOf: answers.appendingPathComponent("count"), encoding: .utf8)).flatMap { Int($0) } ?? 0
    }

    func runner(work: Bool = true, dry: Bool = false) -> TaskRunner {
        var runner = TaskRunner(project: fx.project, git: fx.git, gh: gh.runner)
        runner.runOptions = fx.options((work ? "write=a.txt," : "") + "answers=\(answers.path)")
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        runner.retryDelay = .zero
        runner.dryRun = dry
        return runner
    }

    func events(_ kind: EventKind? = nil) throws -> [Event] {
        let all = try EventLogReader.read(at: task.log.url).events
        return kind.map { kind in all.filter { $0.kind == kind } } ?? all
    }

    func threads() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fx.project.threadsDirectory.path)) ?? []).sorted()
    }
}

/// A read-only agent that answers every candidate `gated` and notes which commit its checkout was at.
private final class ProbeAgent: ReadOnlyAgent, @unchecked Sendable {
    private let git: GitRunner
    private let lock = NSLock()
    private var seen: [String] = []

    init(git: GitRunner) { self.git = git }

    var heads: [String] { lock.withLock { seen } }

    func unavailable() -> String? { nil }
    func shownArguments(for request: ReadOnlyRequest) -> [String] { [] }

    func run(_ request: ReadOnlyRequest, attach: @Sendable (ProcessRun) -> Void) async -> ReadOnlyAnswer {
        let head = try? await git.run(["rev-parse", "HEAD"], in: request.workingDirectory)
        lock.withLock { seen.append(head?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?") }
        let rows = ["ROU", "TUR", "PAN"].filter { request.prompt.contains("- \($0): ") }.map {
            "{\"id\": \"\($0)\", \"verdict\": \"gated\", \"reason\": \"probe\"}"
        }
        let answer = "{\"units\": [\(rows.joined(separator: ","))], \"concerns\": []}"
        return ReadOnlyAnswer(text: answer, costUSD: 0.001, failure: nil)
    }
}

@Suite(.processGate) struct TaskGateRunTests {
    @Test func theGateReadsTheBaseTheWorkerWouldStartFromNotAStaleLocalOne() async throws {
        let run = try await Gated(front: "batch: 2\ngate_rounds: 1")
        let bare = try await addOrigin(run.fx)
        // Origin moves on without this checkout hearing of it.
        let other = run.fx.repo.deletingLastPathComponent().appendingPathComponent("other-\(UUID().uuidString)")
        _ = try await run.fx.git.run(["clone", "-q", "-b", "main", bare.path, other.path], in: run.fx.repo)
        try "newer\n".write(to: other.appendingPathComponent("newer.txt"), atomically: true, encoding: .utf8)
        _ = try await run.fx.git.run(["add", "."], in: other)
        _ = try await run.fx.git.run(["commit", "-q", "-m", "newer"], in: other)
        _ = try await run.fx.git.run(["push", "-q", "origin", "HEAD:main"], in: other)
        func sha(_ ref: String, in folder: URL) async throws -> String {
            try await run.fx.git.run(["rev-parse", ref], in: folder).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let newest = try await sha("HEAD", in: other)
        let local = try await sha("main", in: run.fx.repo)
        #expect(local != newest, "the local main is behind")

        let probe = ProbeAgent(git: run.fx.git)
        var runner = run.runner()
        runner.readOnlyAgent = probe
        let result = await runner.run("bump", trigger: .manual)
        #expect(result.outcome == .nothingToDo, "\(result.reason ?? "")")
        #expect(probe.heads == [newest], "the gate's checkout is the base as origin has it")
    }

    @Test func aGateThatKeepsEverythingAsksOnceAndTheWorkerTakesTheBatch() async throws {
        let run = try await Gated()
        _ = try await addOrigin(run.fx)
        try run.answer(
            gateVerdict([("ROU", "clear", "no flag in v2"), ("TUR", "clear", "no flag in v2")]), Gated.description)
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .prOpened, "\(result.reason ?? "")")
        #expect(result.units == ["ROU", "TUR"])
        #expect(run.asked == 2, "one gate turn and the description, nothing more")
        #expect(try run.events(.taskRunGate).count == 1 && run.events(.taskUnitCleared).count == 2)
        #expect(try run.events(.taskUnitHeld).isEmpty)
        let history = try run.task.log.history()
        #expect(history.held.isEmpty && history.cleared == ["ROU", "TUR"])
    }

    @Test func aGatedUnitIsHeldAndTheBatchIsToppedUpAndAskedAboutAgain() async throws {
        let run = try await Gated()
        _ = try await addOrigin(run.fx)
        try run.answer(
            gateVerdict([("ROU", "clear", "no flag"), ("TUR", "gated", "changelog v2: 'needs flag tur_x' (off)")]),
            gateVerdict([("PAN", "clear", "no flag")]), Gated.description)
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .prOpened, "\(result.reason ?? "")")
        #expect(result.units == ["ROU", "PAN"], "the worker never saw TUR")
        #expect(run.asked == 3, "two gate turns and the description")
        let held = try run.task.log.history().held
        #expect(held.map(\.id) == ["TUR"] && held.first?.reason.contains("tur_x") == true && held.first?.title == "TUR v1 -> v2")

        // In the log: every verdict before the thread exists, so a unit is never both held and taken.
        let kinds = try run.events().map(\.kind.rawValue)
        let thread = try #require(kinds.firstIndex(of: "task.run.thread"))
        for kind in ["task.unit.held", "task.unit.cleared", "task.run.gate"] {
            #expect(kinds.enumerated().filter { $1 == kind }.allSatisfy { $0.offset < thread }, "\(kind) comes before the thread")
        }
        let rounds = try run.events(.taskRunGate)
        #expect(rounds.map { $0.data["round"] } == [.int(1), .int(2)])
        #expect(rounds[0].data["gated"]?.arrayItems?.first?["unit"]?.stringValue == "TUR")
        let taken = try #require(run.events(.taskRunThread).first)
        #expect(taken.data["units"]?.arrayItems?.compactMap(\.stringValue) == ["ROU", "PAN"])
    }

    @Test func aUnitTheGateCouldNotCheckIsNeitherHeldNorClearedAndIsAskedAboutAgainNextRun() async throws {
        let run = try await Gated()
        _ = try await addOrigin(run.fx)
        try run.answer(
            gateVerdict([("ROU", "clear", "no flag"), ("TUR", "unknown", "git show: not a git repository")]),
            gateVerdict([("PAN", "clear", "no flag")]), Gated.description)
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .prOpened && result.units == ["ROU", "PAN"], "\(result.reason ?? "")")
        let history = try run.task.log.history()
        #expect(history.held.isEmpty && history.cleared == ["ROU", "PAN"], "nothing is recorded of TUR")
        #expect(try run.events(.taskUnitHeld).isEmpty)
        let round = try #require(run.events(.taskRunGate).first)
        #expect(round.data["unknown"]?.arrayItems?.first?["unit"]?.stringValue == "TUR")
        let turEvents = try run.events().filter { $0.data["unit"]?.stringValue == "TUR" }
        #expect(turEvents.isEmpty, "no unit event names it")

        // TUR is still pending, so the next run asks about it, and about it alone.
        try run.answer(gateVerdict([("TUR", "gated", "now readable: needs flag tur_x")]))
        let next = await run.runner(dry: true).run("bump", trigger: .manual)
        #expect(next.reason?.contains("held: TUR (now readable") == true && run.asked == 1)
    }

    @Test func aGateThatCouldCheckNothingFailsTheRunAndHoldsNothing() async throws {
        let run = try await Gated()
        try run.answer(
            gateVerdict([("ROU", "unknown", "origin/master does not exist here"), ("TUR", "unknown", "same")]),
            gateVerdict([("PAN", "unknown", "same")]))
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.thread == nil, "a command that did not work is a problem, not a hold")
        let expected = "the gate could not check: ROU (origin/master does not exist here); TUR (same); PAN (same)"
        #expect(result.reason?.contains(expected) == true)
        #expect(result.units == ["ROU", "TUR", "PAN"], "they go after the untried ones next time")
        #expect(run.threads().isEmpty)
        #expect(try run.task.log.history().held.isEmpty && run.task.log.history().cleared.isEmpty)
    }

    @Test func aGateThatHoldsEverythingStartsNoThreadAndNoPullRequest() async throws {
        let run = try await Gated()
        try run.answer(
            gateVerdict([("ROU", "gated", "flag a is off"), ("TUR", "gated", "flag b is off")]),
            gateVerdict([("PAN", "gated", "flag c is off")]))
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .nothingToDo && result.thread == nil && result.pullRequest == nil && result.units.isEmpty)
        let reason = result.reason ?? ""
        let expectations = ["ROU (flag a is off)", "TUR (flag b is off)", "PAN (flag c is off)", "no more candidates"]
        for expected in expectations {
            #expect(reason.contains(expected), "\(reason)")
        }
        #expect(run.threads().isEmpty, "no thread was made")
        #expect(try run.task.log.history().held.map(\.id) == ["ROU", "TUR", "PAN"])

        // The next run has nothing to offer, says why, and does not ask the gate again.
        try run.answer()
        let again = await run.runner().run("bump", trigger: .manual)
        #expect(again.outcome == .nothingPending && again.reason?.contains("3 held by the gate") == true)
        #expect(run.asked == 0)
    }

    @Test func theRoundLimitShipsWhatWasClearAndSaysSo() async throws {
        let run = try await Gated(front: "batch: 2\ngate_rounds: 1")
        _ = try await addOrigin(run.fx)
        try run.answer(
            gateVerdict([("ROU", "gated", "flag a is off"), ("TUR", "clear", "no flag")]), Gated.description)
        let said = Said()
        var runner = run.runner()
        runner.notice = { said.add($0) }
        let result = await runner.run("bump", trigger: .manual)
        #expect(result.outcome == .prOpened && result.units == ["TUR"], "\(result.reason ?? "")")
        #expect(run.asked == 2, "no second gate turn")
        #expect(said.lines.contains { $0.contains("the round limit (gate_rounds) was reached") })
    }

    @Test func anAnswerThatIsNotUsableFailsTheRunBeforeAnythingIsStarted() async throws {
        let run = try await Gated()
        try run.answer(gateVerdict([("ROU", "gated", nil), ("TUR", "clear", "ok")]))
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.thread == nil)
        let reason = result.reason ?? ""
        #expect(reason.contains("the gate could not decide") && reason.contains("without a reason"))
        #expect(run.threads().isEmpty)
        #expect(try run.events(.taskUnitHeld).isEmpty && run.events(.taskUnitCleared).isEmpty, "nothing recorded")
        #expect(try run.task.log.history().runs.last?.outcome == .failed)
    }

    @Test func aClearedUnitIsNotAskedAboutAgainAndARunThatFailedMidGateKeepsWhatItLearned() async throws {
        let run = try await Gated()
        _ = try await addOrigin(run.fx)
        // Round 1 decides ROU and TUR; round 2's answer is not JSON, so the run fails with those two verdicts on record.
        try run.answer(
            gateVerdict([("ROU", "clear", "no flag"), ("TUR", "gated", "flag t is off")]), "no json at all")
        let failed = await run.runner().run("bump", trigger: .manual)
        #expect(failed.outcome == .failed && failed.thread == nil)
        let history = try run.task.log.history()
        #expect(history.cleared == ["ROU"] && history.held.map(\.id) == ["TUR"])

        // The next run asks only about what it does not know: PAN. An answer that also covered ROU would be refused.
        try run.answer(gateVerdict([("PAN", "clear", "no flag")]), Gated.description)
        let next = await run.runner().run("bump", trigger: .manual)
        #expect(next.outcome == .prOpened && next.units == ["ROU", "PAN"], "\(next.reason ?? "")")
        #expect(run.asked == 2)
    }

    @Test func aDryRunAsksTheGateAndWritesNoVerdicts() async throws {
        let run = try await Gated()
        try run.answer(
            gateVerdict([("ROU", "clear", "no flag"), ("TUR", "gated", "flag t is off")]), gateVerdict([("PAN", "clear", "ok")]))
        let said = Said()
        var runner = run.runner(dry: true)
        runner.notice = { said.add($0) }
        let result = await runner.run("bump", trigger: .manual)
        #expect(result.outcome == .reported && result.units == ["ROU", "PAN"] && result.thread == nil)
        #expect(result.reason == "dry run (gate): would take ROU, PAN; held: TUR (flag t is off)")
        #expect(said.lines.contains { $0.contains("gate: TUR held: flag t is off") })
        for kind in [EventKind.taskUnitHeld, .taskUnitCleared, .taskRunGate, .taskUnitReleased] {
            #expect(try run.events(kind).isEmpty, "\(kind.rawValue)")
        }
        #expect(run.threads().isEmpty && run.asked == 2)
        #expect(try run.task.log.history().held.isEmpty)
    }

    @Test func aUnitTheScriptStopsListingIsForgotten() async throws {
        let run = try await Gated()
        try run.answer(
            gateVerdict([("ROU", "gated", "flag a is off"), ("TUR", "gated", "flag b is off")]),
            gateVerdict([("PAN", "gated", "flag c is off")]))
        _ = await run.runner().run("bump", trigger: .manual)
        #expect(try run.task.log.history().held.map(\.id) == ["ROU", "TUR", "PAN"])

        // A newer version has a new id: the old one is gone from the list, and so from the held units.
        try run.setPending(["ROU", "TUR", "PAN2"])
        try await run.task.library.approve("bump")
        try run.answer(gateVerdict([("PAN2", "gated", "flag d is off")]))
        _ = await run.runner().run("bump", trigger: .manual)
        let released = try run.events(.taskUnitReleased)
        #expect(released.compactMap { $0.data["unit"]?.stringValue } == ["PAN"])
        #expect(released.first?.data["why"]?.stringValue == "no longer listed")
        #expect(try run.task.log.history().held.map(\.id) == ["ROU", "TUR", "PAN2"])
    }

    @Test func aPersonReleasesAHeldUnitAndTheNextRunOffersItAgain() async throws {
        let run = try await Gated(front: "batch: 1\ngate_rounds: 1", pending: ["ROU"])
        try run.answer(gateVerdict([("ROU", "gated", "flag a is off")]))
        _ = await run.runner().run("bump", trigger: .manual)
        #expect(try run.task.log.history().held.map(\.id) == ["ROU"])

        do {
            try await run.task.library.release("TUR", of: "bump")
            Issue.record("a unit that is not held was released")
        } catch let error as TaskStateError { #expect(error == .notHeld("TUR")) }
        do {
            try await run.task.library.release("ROU", of: "nothing")
            Issue.record("a task that is not there")
        } catch let error as TaskStateError { #expect(error == .notFound("nothing")) }
        try await run.task.library.release("ROU", of: "bump")
        #expect(try run.task.log.history().held.isEmpty)
        #expect(try run.events(.taskUnitReleased).first?.data["why"]?.stringValue == "person")

        try run.answer(gateVerdict([("ROU", "gated", "flag a is still off")]))
        let again = await run.runner().run("bump", trigger: .manual)
        #expect(again.outcome == .nothingToDo && run.asked == 1, "the released unit was asked about again")
    }

    @Test func aRunThatDiedInTheGateHoldsNoUnitAndTakesNone() async throws {
        let run = try await Gated()
        // What a killed run leaves: its start, a verdict that held one unit and cleared another, and no end.
        let writer = try await run.task.log.openWriter()
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(
            .taskUnitHeld, data: ["unit": "TUR", "title": "TUR v1 -> v2", "reason": "flag t is off", "round": 1])
        try await writer.append(.taskUnitCleared, data: ["unit": "ROU", "title": "ROU v1 -> v2", "reason": "no flag", "round": 1])
        await writer.close()
        #expect(try run.task.log.history().openRun != nil)

        // The next writer closes it as interrupted, with no thread and no unit: nothing was taken, nothing is lost.
        let next = try await run.task.log.openWriter()
        await next.close()
        let history = try run.task.log.history()
        let died = try #require(history.runs.first)
        #expect(died.outcome == .interrupted && died.thread == nil && died.units.isEmpty)
        #expect(history.held.map(\.id) == ["TUR"] && history.cleared == ["ROU"])
        #expect(history.unitsWithThreads.isEmpty && history.failedTries.isEmpty)
        let pending = PendingUnits.select(
            units: gateUnits("ROU", "TUR", "PAN"), history: history, pullRequests: [:], batch: 3)
        #expect(pending.map(\.id) == ["ROU", "PAN"], "held and pending never overlap")
    }

    @Test func aRunBudgetBelowTheWorkersBudgetIsRefusedBeforeAnythingIsSpent() async throws {
        // The worker alone may spend the project's default budget (1.00): a run budget under it could not be kept.
        let run = try await Gated(front: "batch: 2\nrun_budget: 0.50")
        try run.answer(gateVerdict([("ROU", "clear", "ok"), ("TUR", "clear", "ok")]))
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("run_budget 0.5 is less than the worker's budget 1") == true)
        #expect(run.asked == 0 && run.threads().isEmpty)
    }

    @Test func aRunBudgetThatLeavesNothingForTheGateIsRefused() async throws {
        let run = try await Gated(front: "batch: 2\nrun_budget: 1.00")
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("leaves nothing for the gate") == true)
        #expect(run.asked == 0 && run.threads().isEmpty)
    }

    @Test func theGateStopsAskingWhenTheRunBudgetIsSpent() async throws {
        // 0.0015 is left for the gate and each fake turn costs 0.001: two rounds fit, a third does not.
        let run = try await Gated(
            front: "batch: 2\ngate_rounds: 5\nrun_budget: 1.0015", pending: ["ROU", "TUR", "PAN", "ESP", "FRA"])
        try run.answer(
            gateVerdict([("ROU", "gated", "a"), ("TUR", "gated", "b")]),
            gateVerdict([("PAN", "gated", "c"), ("ESP", "gated", "d")]))
        let said = Said()
        var runner = run.runner()
        runner.notice = { said.add($0) }
        let result = await runner.run("bump", trigger: .manual)
        #expect(result.outcome == .nothingToDo && result.reason?.contains("the run's budget leaves no room") == true)
        #expect(run.asked == 2 && run.threads().isEmpty)
        #expect(try run.task.log.history().held.map(\.id) == ["ROU", "TUR", "PAN", "ESP"], "FRA was never asked about")
    }

    @Test func aGateOnCodexIsRefusedBecauseItCannotBeHeldToAToolList() async throws {
        let run = try await Gated(extraConfig: "\n[agents.judge]\nprovider = \"codex\"\nallow_unpriced = true\n")
        try run.answer(gateVerdict([("ROU", "clear", "ok"), ("TUR", "clear", "ok")]))
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("a gate needs Claude") == true, "\(result.reason ?? "")")
        #expect(run.asked == 0 && run.threads().isEmpty)
    }

    @Test func aHeldUnitIsForgottenEvenWhenTheScriptListsNothingAtAll() async throws {
        let run = try await Gated(front: "batch: 1\ngate_rounds: 1", pending: ["TUR"])
        try run.answer(gateVerdict([("TUR", "gated", "flag t is off")]))
        _ = await run.runner().run("bump", trigger: .manual)
        #expect(try run.task.log.history().held.map(\.id) == ["TUR"])

        try run.setPending([])
        try await run.task.library.approve("bump")
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .nothingPending)
        #expect(try run.events(.taskUnitReleased).first?.data["why"]?.stringValue == "no longer listed")
        #expect(try run.task.log.history().held.isEmpty, "a unit the script no longer names is not held for ever")
    }

    @Test func aTaskWithoutAGateRunsAsItAlwaysDid() async throws {
        let fx = try await RunnerFixture(extraConfig: "max_active_threads = 1\ncheck_command = \"true\"")
        let task = try TaskFixture(in: fx.project, front: "fix: pr\nbatch: 2\npending: pending.sh")
        let gh = try FakeGH(in: fx)
        try task.script(#"echo '[{"id":"ROU"},{"id":"TUR"},{"id":"PAN"}]'"#)
        try await task.library.approve(task.name)
        _ = try await addOrigin(fx)
        let answer = fx.repo.deletingLastPathComponent().appendingPathComponent("answer-\(UUID().uuidString).txt")
        try Gated.description.write(to: answer, atomically: true, encoding: .utf8)
        var runner = TaskRunner(project: fx.project, git: fx.git, gh: gh.runner)
        runner.runOptions = fx.options("write=a.txt", "answer=\(answer.path)")
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let result = await runner.run("bump", trigger: .manual)
        #expect(result.outcome == .prOpened && result.units == ["ROU", "TUR"], "\(result.reason ?? "")")
        let kinds = try EventLogReader.read(at: task.log.url).events.map(\.kind.rawValue)
        #expect(!kinds.contains { $0 == "task.run.gate" || $0 == "task.unit.held" || $0 == "task.unit.cleared" })
    }
}

final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ line: String) { lock.withLock { items.append(line) } }
    var lines: [String] { lock.withLock { items } }
}
