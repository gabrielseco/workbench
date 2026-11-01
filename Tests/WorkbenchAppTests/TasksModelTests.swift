import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct TasksModelTests {
    /// The `tasks` scenario as a project on disk, read with stand-in timer answers (nothing asks the machine).
    private func scenario() async throws -> (AppFixture, [String: String]) {
        let fixture = try await AppFixture(git: false)
        try await AppScenario.tasks.build(in: fixture)
        let probes = fixture.root.appendingPathComponent("probes")
        try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)
        try "Repeating power events:\n".write(to: probes.appendingPathComponent("sched"), atomically: true, encoding: .utf8)
        try "Now drawing from 'AC Power'\n".write(to: probes.appendingPathComponent("power"), atomically: true, encoding: .utf8)
        try "FileVault is On.\n".write(to: probes.appendingPathComponent("filevault"), atomically: true, encoding: .utf8)
        let env = [
            "WORKBENCH_APP_HOME": fixture.root.appendingPathComponent("home").path,
            "WORKBENCH_APP_LAUNCHCTL": "/nonexistent/launchctl", "WORKBENCH_APP_PROBES": probes.path,
        ]
        return (fixture, env)
    }

    private func snapshot(_ fixture: AppFixture, _ env: [String: String]) async throws -> TasksSnapshot {
        try await TasksReader.core(environment: env).read(fixture.project, Date(timeIntervalSince1970: 1_793_500_000))
    }

    @Test func switchKeepsThreadScreen() async throws {
        let fixture = try await AppFixture()
        try await AppScenario.needsYou.build(in: fixture)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil))
        #expect(await store.open(fixture.project.root))
        let before = store.screen
        store.mode = .tasks
        #expect(store.screen == before)
        store.mode = .thread
        #expect(store.screen == before)
        #expect(store.mode == .thread)
    }

    @Test func rowsMirrorSummary() async throws {
        let (fixture, env) = try await scenario()
        let shown = try await snapshot(fixture, env)
        let library = TaskLibrary(project: fixture.project)
        #expect(shown.entries.map(\.id) == library.names())
        for entry in shown.entries {
            #expect(entry.summary == library.summary(entry.id, now: shown.readAt))
        }
        let byName = Dictionary(uniqueKeysWithValues: shown.entries.map { ($0.id, $0.summary) })
        #expect(byName["bump-contract-details"]?.approval == .approved)
        #expect(byName["bump-contract-details"]?.schedule == "weekdays 04:00")
        #expect(byName["update-docs"]?.approval == .stale)
        #expect(byName["cleanup-branches"]?.approval == .never)
        #expect(byName["broken-task"]?.problem != nil)
    }

    @Test func timelineFromHistory() async throws {
        let (fixture, env) = try await scenario()
        let entry = try #require(try await snapshot(fixture, env).entries.first { $0.id == "bump-contract-details" })
        let history = try TaskRunLog(project: fixture.project, name: "bump-contract-details").history()
        #expect(entry.runs == history.runs.reversed())
        #expect(entry.runs.map(\.outcome) == [.skippedTooManyOpen, .prOpened, .prOpened])
        #expect(entry.runs.last?.units == ["ROU", "TUR", "CZE"])
        #expect(entry.runs.last?.thread == "invoice-pagination")
        #expect(entry.runs.last?.pullRequest?.hasSuffix("/pull/412") == true)
        #expect(TasksText.reason(entry.runs[0])?.contains("#412") == true)
    }

    @Test func openRunIsWorking() async throws {
        let (fixture, env) = try await scenario()
        let entry = try #require(try await snapshot(fixture, env).entries.first { $0.id == "nightly-lint" })
        #expect(entry.isRunning)
        #expect(entry.runs.first?.outcome == nil)
        #expect(TaskOutcomeStyle.tone(nil) == .working)
        #expect(TaskOutcomeStyle.word(nil) == "running")
        let other = try #require(try await snapshot(fixture, env).entries.first { $0.id == "sync-fixtures" })
        #expect(!other.isRunning)
    }

    @Test func reasonIsTheCores() {
        func run(_ reason: String?) -> TaskHistory.Run {
            TaskHistory.Run(
                started: Date(), ended: Date(), pullRequest: nil, trigger: "tick", outcome: .failed, reason: reason, units: [],
                thread: nil)
        }
        let dirty = TasksText.reason(run("line one\nline\u{0}two\u{1b}[31m   spaced"))
        #expect(dirty == "line one line two [31m spaced")
        let long = TasksText.reason(run(String(repeating: "x", count: 5000)))
        #expect(long?.count == TaskExplanation.maxReason)
        #expect(long?.hasSuffix("…") == true)
        #expect(TasksText.reason(run(nil)) == nil)
        #expect(TasksText.reason(run("  \n ")) == nil)
    }

    @Test func threadLinkOnlyWhenThreadExists() {
        func run(_ thread: String?) -> TaskHistory.Run {
            TaskHistory.Run(
                started: Date(), ended: nil, pullRequest: nil, trigger: "tick", outcome: .prOpened, reason: nil, units: [],
                thread: thread)
        }
        #expect(TasksText.canOpenThread(run("t1"), onScreen: "t1"))
        #expect(!TasksText.canOpenThread(run("t1"), onScreen: "t2"))
        #expect(!TasksText.canOpenThread(run("t1"), onScreen: nil))
        #expect(!TasksText.canOpenThread(run(nil), onScreen: nil))
    }

    @Test func timerCardMirrorsStatus() async throws {
        let (fixture, env) = try await scenario()
        let shown = try await snapshot(fixture, env)
        let service = TasksReader.timerService(project: fixture.project, environment: env)
        let expected = await service.status()
        #expect(shown.timer == .lines(expected))
        // No launchctl here, so the agent line is not an ok: the headline is the worst line, never greener than the lines.
        #expect(expected.contains { $0.level != .ok })
        #expect(shown.timer.worst == (expected.contains { $0.level == .fail } ? .fail : .warn))
        #expect(shown.timer.headline != "Ready for tonight")
        #expect(TimerCard.lines([TimerStatusLine(level: .ok, text: "a")]).headline == "Ready for tonight")
        let mixed = [TimerStatusLine(level: .ok, text: "a"), TimerStatusLine(level: .fail, text: "b")]
        #expect(TimerCard.lines(mixed).worst == .fail)
    }

    @Test func timerUnreadableIsUnknown() async throws {
        let card = TimerCard.unknown("the machine did not answer")
        #expect(card.worst == nil)
        #expect(card.headline == "unknown")
        let (fixture, env) = try await scenario()
        let service = TasksReader.timerService(project: fixture.project, environment: env)
        // A probe that never answers: the card says unknown after its limit.
        var slow = service
        slow.probes = TimerProbes(
            sched: {
                try? await Task.sleep(for: .seconds(30))
                return nil
            }, power: { nil }, fileVault: { nil })
        let shown = await TasksReader.timerCard(slow, limit: .milliseconds(100))
        #expect(shown == .unknown("launchctl, pmset or fdesetup did not answer in time"))
    }

    @Test func outcomeMarks() {
        #expect(TaskOutcomeStyle.tone(.prOpened) == .done)
        #expect(TaskOutcomeStyle.tone(.reported) == .done)
        let idle: [TaskOutcome] = [
            .nothingPending, .nothingToDo, .skippedProjectBusy, .skippedAlreadyRunning, .skippedTooManyOpen,
        ]
        for outcome in idle {
            #expect(TaskOutcomeStyle.tone(outcome) == .idle)
        }
        #expect(TaskOutcomeStyle.tone(.staleApproval) == .needsYou)
        for outcome in [TaskOutcome.failed, .budgetExceeded, .interrupted] { #expect(TaskOutcomeStyle.tone(outcome) == .broken) }
        // Colour is never the only signal: every tone has its own symbol and every outcome a word.
        let symbols = Set([TaskOutcome?.none, .prOpened, .nothingPending, .staleApproval, .failed].map(TaskOutcomeStyle.symbol))
        #expect(symbols.count == 5)
        #expect(TaskOutcomeStyle.word(.skippedTooManyOpen) == "skipped-too-many-open")
        #expect(TaskOutcomeStyle.tone(TimerStatusLine.Level.ok) == .done)
        #expect(TaskOutcomeStyle.tone(TimerStatusLine.Level.warn) == .needsYou)
        #expect(TaskOutcomeStyle.tone(TimerStatusLine.Level.fail) == .broken)
    }

    @Test func refreshRules() async throws {
        let (fixture, env) = try await scenario()
        let clock = ClockHolder(Date(timeIntervalSince1970: 1_000))
        let counter = Counter()
        let fail = Flag()
        let real = TasksReader.core(environment: env)
        let reader = TasksReader { project, now in
            counter.increment()
            if fail.on { throw ReadFailure() }
            return try await real.read(project, now)
        }
        let model = TasksModel(reader: reader, clock: { clock.now })
        let project = fixture.project
        // Not shown: never read.
        await model.refreshIfDue(project, visible: false)
        await model.refreshIfDue(project, visible: false, force: true)
        #expect(counter.count == 0 as Int)
        // Shown: read at once, then only after 30 s; activation reads again.
        await model.refreshIfDue(project, visible: true)
        #expect(counter.count == 1)
        clock.now.addTimeInterval(29)
        await model.refreshIfDue(project, visible: true)
        #expect(counter.count == 1)
        clock.now.addTimeInterval(2)
        await model.refreshIfDue(project, visible: true)
        #expect(counter.count == 2)
        await model.refreshIfDue(project, visible: true, force: true)
        #expect(counter.count == 3)
        // A failed read keeps the last good data and says why.
        let good = model.snapshot(for: project)
        #expect(good?.entries.count == 7)
        fail.on = true
        await model.refresh(project)
        #expect(model.error != nil)
        #expect(model.snapshot(for: project) == good)
        fail.on = false
        await model.refresh(project)
        #expect(model.error == nil)
        // An unreadable tasks folder is a failed read, not an empty list.
        let folder = fixture.project.tasksDirectory
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let kept = TasksModel(reader: real)
        await kept.refresh(project)
        let before = kept.snapshot(for: project)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        await kept.refresh(project)
        #expect(kept.error != nil)
        #expect(kept.snapshot(for: project) == before)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        // Another project's tasks are never shown under this one.
        let other = try await AppFixture(git: false)
        #expect(model.snapshot(for: other.project) == nil)
    }

    @Test func anAnswerForAProjectLeftBehindIsDropped() async throws {
        let (first, env) = try await scenario()
        let second = try await AppFixture(git: false)
        let real = TasksReader.core(environment: env)
        let gate = Gate()
        let slowPath = first.project.root.path
        let reader = TasksReader { project, now in
            // The first project's read is slow: it finishes after the second one has been asked for.
            if project.root.path == slowPath { await gate.wait() }
            return try await real.read(project, now)
        }
        let model = TasksModel(reader: reader)
        let slow = Task { await model.refresh(first.project) }
        try await Task.sleep(for: .milliseconds(50))
        await model.refresh(second.project)
        await gate.open()
        await slow.value
        #expect(model.snapshot(for: second.project) != nil)
        #expect(model.snapshot(for: first.project) == nil)
    }

    @Test func readOnly() async throws {
        let (fixture, env) = try await scenario()
        let tasks = fixture.project.tasksDirectory
        func bytes() throws -> [String: Data] {
            var found: [String: Data] = [:]
            let items = FileManager.default.enumerator(at: tasks, includingPropertiesForKeys: nil)
            while let url = items?.nextObject() as? URL {
                if let data = try? Data(contentsOf: url) { found[url.path] = data }
            }
            return found
        }
        let before = try bytes()
        let model = TasksModel(reader: .core(environment: env))
        await model.refresh(fixture.project)
        await model.refresh(fixture.project)
        #expect(try bytes() == before)
        #expect(model.snapshot(for: fixture.project)?.entries.count == 7)
        // The empty scenario says so rather than failing.
        let empty = try await AppFixture(git: false)
        let none = try await TasksReader.core(environment: env).read(empty.project, Date())
        #expect(none.entries.isEmpty)
    }
}

private struct ReadFailure: Error, CustomStringConvertible { var description: String { "disk gone" } }

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class ClockHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
