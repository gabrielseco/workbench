import Foundation
import Testing

@testable import WorkbenchCore

/// Scripts the `workbench` commands the driver runs: records each call, answers by its first words, and lets a test act when one
/// runs (as the real command would change the thread's log).
private final class FakeCommands: SeriesCommandRunner, @unchecked Sendable {
    struct Call: Equatable {
        var arguments: [String]
        var project: String
        var environment: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var exits: [String: Int32] = [:]
    var onRun: (@Sendable (Call) -> Void)?
    private var made = 0

    var calls: [Call] { lock.withLock { recorded } }
    var words: [String] { calls.map { $0.arguments.prefix(2).joined(separator: " ") } }

    func stop() {}

    func run(
        _ arguments: [String], in project: URL, environment: [String: String], output: @Sendable (String) -> Void
    ) async -> SeriesCommandResult {
        let call = Call(arguments: arguments, project: project.standardizedFileURL.path, environment: environment)
        let key = arguments.prefix(2).joined(separator: " ")
        lock.withLock { recorded.append(call) }
        onRun?(call)
        let exit = exits[key] ?? 0
        if exit != 0 { return SeriesCommandResult(exit: exit, stderr: "boom from \(key)\n") }
        if key == "goal new" {
            let id = lock.withLock { () -> String in
                made += 1
                return "g-2026-11-21-step\(made)"
            }
            return SeriesCommandResult(exit: 0, stdout: ["created \(id)", "base: main"])
        }
        return SeriesCommandResult(exit: 0)
    }
}

private let goalText = """
    ---
    title: Add the thing
    budget_usd: 2.00
    turn_timeout_min: 20
    ---

    ## Request

    Add the thing.

    ## Criteria

    - [c1] The thing exists.
      - proof: a test

    ## Out of scope

    - Everything else.
    """

private struct Rig {
    var fx: RunnerFixture
    var library: SeriesLibrary
    var directory: URL

    init(_ seriesText: String) async throws {
        fx = try await RunnerFixture()
        library = SeriesLibrary(project: fx.project)
        directory = fx.project.seriesDirectory("s")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try seriesText.replacingOccurrences(of: "PROJECT", with: fx.repo.path)
            .write(to: directory.appendingPathComponent("series.md"), atomically: true, encoding: .utf8)
        for file in ["p1.md", "p2.md"] {
            try goalText.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    func driver(_ commands: FakeCommands, states: @escaping StatesProvider) -> SeriesDriver {
        SeriesDriver(library: library, commands: commands, states: states)
    }
}

private typealias StatesProvider = @Sendable (LoadedSeries) async -> [Int: SeriesStepState]

private let twoSteps =
    "## 1\nproject: PROJECT\ngoal: p1.md\n## 2\nproject: PROJECT\ngoal: p2.md\nbase: after 1\nenv: REF=step:1\n"

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// States that follow what the fake commands did: a step is clean once its `ship` ran.
private final class Shipped: @unchecked Sendable {
    private let lock = NSLock()
    private var steps = Set<Int>()
    private var threads: [Int: String] = [:]

    func mark(_ step: Int, thread: String) { lock.withLock { _ = steps.insert(step); threads[step] = thread } }

    func states(_ loaded: LoadedSeries) -> [Int: SeriesStepState] {
        let records = SeriesStepLog(project: Project(root: loaded.projects[1]!), series: loaded.definition.name).read()
        var result: [Int: SeriesStepState] = [:]
        for step in loaded.definition.steps {
            guard let record = records[step.number] else {
                result[step.number] = .pending
                continue
            }
            let isShipped = lock.withLock { steps.contains(step.number) }
            if let reason = record.stopped {
                result[step.number] = .stopped(thread: record.thread, reason: reason)
            } else if isShipped {
                result[step.number] = .clean(thread: record.thread, pullRequest: "https://example.test/pull/\(step.number)")
            } else {
                result[step.number] = .running(thread: record.thread)
            }
        }
        return result
    }
}

@Suite(.processGate) struct SeriesDriverTests {
    @Test func aSeriesThatIsNotApprovedOrIsStaleIsRefusedAndRunsNothing() async throws {
        let rig = try await Rig(twoSteps)
        let commands = FakeCommands()
        do {
            _ = try await rig.driver(commands) { _ in [:] }.run("s")
            Issue.record("expected a refusal")
        } catch let error as SeriesDriverError { #expect(error == .notApproved(.never)) }
        _ = try rig.library.approve("s")
        try goalText.replacingOccurrences(of: "Add the thing.\n", with: "Add another thing.\n")
            .write(to: rig.directory.appendingPathComponent("p1.md"), atomically: true, encoding: .utf8)
        do {
            _ = try await rig.driver(commands) { _ in [:] }.run("s")
            Issue.record("expected a refusal")
        } catch let error as SeriesDriverError { #expect(error == .notApproved(.stale)) }
        #expect(commands.calls.isEmpty)
    }

    @Test func eachStepRunsTheSameCommandsInOrderAndTheSecondStacksOnTheFirst() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let shipped = Shipped()
        let commands = FakeCommands()
        commands.onRun = { call in
            if call.arguments.first == "ship", let id = call.arguments.dropFirst().dropFirst().first {
                shipped.mark(id.hasSuffix("step1") ? 1 : 2, thread: id)
            }
        }
        let result = try await rig.driver(commands, states: shipped.states).run("s")
        #expect(result == .finished)
        #expect(
            commands.words == [
                "goal new", "goal approve", "run --thread", "accept --thread", "ship --thread",
                "goal new", "goal approve", "run --thread", "accept --thread", "ship --thread",
            ])
        let first = commands.calls[0]
        #expect(first.arguments.contains { $0.hasSuffix("/.snapshots/step-1.md") })
        #expect(!first.arguments.contains("--after"))
        #expect(first.environment.isEmpty)
        let ship = commands.calls[4]
        #expect(ship.arguments == ["ship", "--thread", "g-2026-11-21-step1", "--yes", "--review-loop"])
        let second = commands.calls[5]
        #expect(second.arguments.suffix(2) == ["--after", "g-2026-11-21-step1"])
        #expect(second.environment["REF"] == "origin/workbench/g-2026-11-21-step1")
        #expect(second.project == rig.fx.repo.standardizedFileURL.path)
    }

    @Test func aFailedCommandStopsTheSeriesRecordsWhyAndStartsNothingElse() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let shipped = Shipped()
        let commands = FakeCommands()
        commands.exits["run --thread"] = 13
        let result = try await rig.driver(commands, states: shipped.states).run("s")
        guard case .stopped(let step, let reason) = result else {
            Issue.record("expected stopped, got \(result)")
            return
        }
        #expect(step == 1)
        #expect(reason.contains("`run` exited 13") && reason.contains("boom from run --thread"))
        #expect(commands.words == ["goal new", "goal approve", "run --thread"])
        let record = SeriesStepLog(project: rig.fx.project, series: "s").read()[1]
        #expect(record?.stopped == reason)
        #expect(record?.thread == "g-2026-11-21-step1")
    }

    @Test func aGoalNewThatFailsOrNamesNoThreadStopsBeforeAnythingIsRecorded() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let commands = FakeCommands()
        commands.exits["goal new"] = 6
        let result = try await rig.driver(commands) { _ in [:] }.run("s")
        guard case .stopped(1, let reason) = result else {
            Issue.record("expected stopped, got \(result)")
            return
        }
        #expect(reason.contains("`goal new` exited 6"))
        #expect(SeriesStepLog(project: rig.fx.project, series: "s").read().isEmpty)
    }

    @Test func aSeriesAlreadyStoppedStartsNothing() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let commands = FakeCommands()
        let result = try await rig.driver(commands) { _ in [1: .stopped(thread: "t", reason: "checks failed: test")] }.run("s")
        #expect(result == .stopped(step: 1, reason: "checks failed: test"))
        #expect(commands.calls.isEmpty)
    }

    @Test func aStepThatWaitsForCIOrAPersonEndsTheRunAndNamesIt() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let commands = FakeCommands()
        let result = try await rig.driver(commands) { _ in
            [1: .waiting(thread: "t", reason: "the checks are still running")]
        }.run("s")
        #expect(result == .waiting(step: 1, reason: "t: the checks are still running"))
        #expect(commands.calls.isEmpty)
    }

    @Test func aStepThatRanButIsNotCleanAfterwardsEndsTheRunWaitingInsteadOfStartingTheNext() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let commands = FakeCommands()
        let result = try await rig.driver(commands) { loaded in
            let records = SeriesStepLog(project: Project(root: loaded.projects[1]!), series: "s").read()
            guard let record = records[1] else { return [:] }
            return [1: .waiting(thread: record.thread, reason: "the review asked for fixes")]
        }.run("s")
        guard case .waiting(1, let reason) = result else {
            Issue.record("expected waiting, got \(result)")
            return
        }
        #expect(reason.contains("the review asked for fixes"))
        #expect(commands.words.filter { $0 == "goal new" }.count == 1)
    }

    @Test func shipIsNeverGivenWatchBecauseTheReviewLoopRefusesTheCombination() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let shipped = Shipped()
        let commands = FakeCommands()
        commands.onRun = { call in
            if call.arguments.first == "ship", let id = call.arguments.dropFirst().dropFirst().first {
                shipped.mark(id.hasSuffix("step1") ? 1 : 2, thread: id)
            }
        }
        _ = try await rig.driver(commands, states: shipped.states).run("s")
        for call in commands.calls where call.arguments.first == "ship" {
            #expect(call.arguments.contains("--review-loop") && !call.arguments.contains("--watch"))
        }
    }

    @Test func aGoalFileEditedWhileAStepRunsIsNotStartedWithoutANewApproval() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let shipped = Shipped()
        let commands = FakeCommands()
        let second = rig.directory.appendingPathComponent("p2.md")
        commands.onRun = { call in
            if call.arguments.first == "ship", let id = call.arguments.dropFirst().dropFirst().first {
                shipped.mark(1, thread: id)
                try? goalText.replacingOccurrences(of: "Add the thing.\n", with: "Add a different thing.\n")
                    .write(to: second, atomically: true, encoding: .utf8)
            }
        }
        do {
            _ = try await rig.driver(commands, states: shipped.states).run("s")
            Issue.record("expected the changed goal to need a new approval")
        } catch let error as SeriesDriverError { #expect(error == .notApproved(.stale)) }
        #expect(commands.words.filter { $0 == "goal new" }.count == 1)
    }

    @Test func theGoalHandedToGoalNewIsTheApprovedTextEvenIfTheFileChangesAfter() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let first = rig.directory.appendingPathComponent("p1.md")
        let commands = FakeCommands()
        commands.onRun = { call in
            // What `goal new --from` would read: the snapshot, which the file edit that follows cannot change.
            if call.arguments.prefix(2) == ["goal", "new"], let path = call.arguments.last(where: { $0.hasSuffix(".md") }) {
                #expect((try? String(contentsOfFile: path, encoding: .utf8)) == goalText)
                try? "tampered".write(to: first, atomically: true, encoding: .utf8)
            }
        }
        commands.exits["goal approve"] = 9
        _ = try await rig.driver(commands) { _ in [:] }.run("s")
        #expect(commands.words.first == "goal new")
    }

    @Test func aStepWhoseChecksAreStillRunningIsWaitedForAndThenNextStarts() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let shipped = Shipped()
        let polls = Counter()
        let commands = FakeCommands()
        commands.onRun = { call in
            if call.arguments.first == "ship", let id = call.arguments.dropFirst().dropFirst().first {
                shipped.mark(id.hasSuffix("step1") ? 1 : 2, thread: id)
            }
        }
        var driver = rig.driver(commands) { loaded in
            var states = shipped.states(loaded)
            // The first step's checks are running for the first two looks after it shipped.
            if case .clean(let thread, _)? = states[1], polls.next() <= 2 {
                states[1] = .waiting(thread: thread, reason: SeriesScheduler.checksRunning)
            }
            return states
        }
        driver.sleep = { _ in }
        let result = try await driver.run("s")
        #expect(result == .finished)
        #expect(commands.words.filter { $0 == "goal new" }.count == 2)
    }

    @Test func checksThatNeverFinishEndTheRunWaitingAfterTheTimeout() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let commands = FakeCommands()
        var driver = rig.driver(commands) { loaded in
            let records = SeriesStepLog(project: Project(root: loaded.projects[1]!), series: "s").read()
            guard let record = records[1] else { return [:] }
            return [1: .waiting(thread: record.thread, reason: SeriesScheduler.checksRunning)]
        }
        driver.sleep = { _ in }
        driver.settleTimeout = 90
        driver.settleInterval = 30
        let result = try await driver.run("s")
        guard case .waiting(1, let reason) = result else {
            Issue.record("expected waiting, got \(result)")
            return
        }
        #expect(reason.contains("still running"))
        #expect(commands.words.filter { $0 == "goal new" }.count == 1)
    }

    @Test func aRunThatDiedAfterGoalNewIsFoundAgainAndNoSecondThreadIsMade() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let log = SeriesStepLog(project: rig.fx.project, series: "s")
        try log.markStarting(step: 1, at: "t0")
        let thread = "g-2026-11-21-s-1"
        try FileManager.default.createDirectory(at: rig.fx.project.threadDirectory(thread), withIntermediateDirectories: true)
        let commands = FakeCommands()
        let result = try await rig.driver(commands) { _ in [:] }.run("s")
        guard case .stopped(1, let reason) = result else {
            Issue.record("expected stopped, got \(result)")
            return
        }
        #expect(reason.contains(thread))
        #expect(log.read()[1]?.thread == thread)
        #expect(commands.calls.isEmpty)
    }

    @Test func aMarkerWithNoThreadIsClearedAndTheStepStartsOnce() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let log = SeriesStepLog(project: rig.fx.project, series: "s")
        try log.markStarting(step: 1, at: "t0")
        let shipped = Shipped()
        let commands = FakeCommands()
        commands.exits["goal approve"] = 9
        _ = try await rig.driver(commands, states: shipped.states).run("s")
        #expect(commands.words.filter { $0 == "goal new" }.count == 1)
        #expect(log.starting().isEmpty)
    }

    @Test func severalThreadsFromAnEarlierDeadRunAreLeftForAPerson() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let log = SeriesStepLog(project: rig.fx.project, series: "s")
        try log.markStarting(step: 1, at: "t0")
        for thread in ["g-2026-11-21-s-1", "g-2026-11-22-s-1"] {
            try FileManager.default.createDirectory(at: rig.fx.project.threadDirectory(thread), withIntermediateDirectories: true)
        }
        let commands = FakeCommands()
        let result = try await rig.driver(commands) { _ in [:] }.run("s")
        guard case .stopped(1, let reason) = result else {
            Issue.record("expected stopped, got \(result)")
            return
        }
        #expect(reason.contains("several threads"))
        #expect(commands.calls.isEmpty)
    }

    @Test func aSecondRunOfTheSameSeriesIsRefusedWhileTheFirstHoldsTheLock() async throws {
        let rig = try await Rig(twoSteps)
        _ = try rig.library.approve("s")
        let lock = rig.directory.appendingPathComponent("run.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o600)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { close(fd) }
        let commands = FakeCommands()
        do {
            _ = try await rig.driver(commands) { _ in [:] }.run("s")
            Issue.record("expected a refusal")
        } catch let error as SeriesDriverError { #expect(error == .alreadyRunning) }
        #expect(commands.calls.isEmpty)
    }

    @Test func aStepWhoseGoalBudgetDoesNotFitInWhatIsLeftOfTheSeriesBudgetDoesNotStart() async throws {
        let rig = try await Rig("---\nbudget_usd: 1.00\n---\n" + twoSteps)
        _ = try rig.library.approve("s")
        let commands = FakeCommands()
        let result = try await rig.driver(commands) { _ in [:] }.run("s")
        guard case .stopped(1, let reason) = result else {
            Issue.record("expected stopped, got \(result)")
            return
        }
        #expect(reason.contains("does not fit"))
        #expect(commands.calls.isEmpty)
    }

    @Test func theSeriesBudgetStopsBeforeAStepStartsOnceTheThreadsHaveSpentIt() async throws {
        let rig = try await Rig("---\nbudget_usd: 1.00\n---\n" + twoSteps)
        _ = try rig.library.approve("s")
        let thread = "g-2026-11-21-step1"
        let dir = rig.fx.project.threadDirectory(thread)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ended = #"{"v":1,"seq":1,"ts":"2026-11-21T10:00:00.000Z","turn":1,"kind":"turn.ended","#
            + #""data":{"result":"succeeded","cost_usd":1.5}}"#
        try (ended + "\n").write(to: rig.fx.project.eventsURL(thread), atomically: true, encoding: .utf8)
        try SeriesStepLog(project: rig.fx.project, series: "s").append(SeriesRecord(step: 1, thread: thread, at: "t"))
        let commands = FakeCommands()
        let clean = SeriesStepState.clean(thread: thread, pullRequest: nil)
        let result = try await rig.driver(commands) { _ in [1: clean] }.run("s")
        guard case .stopped(2, let reason) = result else {
            Issue.record("expected stopped at 2, got \(result)")
            return
        }
        #expect(reason.contains("series budget"))
        #expect(commands.calls.isEmpty)
    }
}

@Suite(.processGate) struct WorkbenchProcessRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let tmp = FileManager.default.temporaryDirectory

    @Test func aCommandsOutputAndExitCodeComeBack() async {
        let runner = WorkbenchProcessRunner(binary: shell, environment: ["PATH": "/usr/bin:/bin"])
        let result = await runner.run(
            ["-c", "echo created $WHO; echo oops >&2; exit 3"], in: FileManager.default.temporaryDirectory,
            environment: ["WHO": "g-1-x"], output: { _ in })
        #expect(result.exit == 3)
        #expect(result.stdout == ["created g-1-x"])
        #expect(result.stderr.contains("oops"))
    }

    @Test func stopEndsTheRunningCommandAndALaterCommandStartsStopped() async {
        let runner = WorkbenchProcessRunner(binary: shell, environment: ["PATH": "/usr/bin:/bin"])
        let tmp = self.tmp
        let started = Task { await runner.run(["-c", "sleep 60"], in: tmp, environment: [:], output: { _ in }) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        runner.stop()
        let result = await started.value
        #expect(result.exit != 0)
        let again = await runner.run(["-c", "sleep 60"], in: tmp, environment: [:], output: { _ in })
        #expect(again.exit != 0)
    }
}
