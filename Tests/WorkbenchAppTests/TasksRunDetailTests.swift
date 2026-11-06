import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct TasksRunDetailTests {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Date] = []
        var count: Int { lock.withLock { seen.count } }
        var isEmpty: Bool { lock.withLock { seen.isEmpty } }
        func read(_ run: TaskHistory.Run) { lock.withLock { seen.append(run.started) } }
    }

    private let run = TaskHistory.Run(
        started: Date(timeIntervalSince1970: 1_793_000_000), ended: Date(timeIntervalSince1970: 1_793_000_090), pullRequest: nil,
        trigger: "tick", outcome: .failed, reason: nil, units: [], thread: "g-x")
    private let detail = TaskRunDetail(
        source: .read, duration: 90, costUSD: 0.75, setup: TaskRunDetail.Step(result: "passed", seconds: 3),
        check: TaskRunDetail.Check(result: "failed", seconds: 5, tail: ["boom"]), denied: 2, agentMessage: "the final answer")

    @Test func runDetailLoadsOnOpen() async throws {
        let fixture = try await AppFixture(git: false)
        try await AppScenario.tasks.build(in: fixture)
        let reads = Reads()
        let shown = detail
        let actions = TaskActions(
            inspect: TaskActions.core.inspect, approve: TaskActions.core.approve, run: TaskActions.core.run,
            detail: { _, run in
                reads.read(run)
                return shown
            })
        let tasks = TasksModel(reader: .core(), actions: actions)
        await tasks.refresh(fixture.project)
        await tasks.refresh(fixture.project)
        #expect(reads.isEmpty, "reading the tasks never reads a thread's log")
        #expect(tasks.detail(fixture.project, "bump", run) == nil && !tasks.isOpen(fixture.project, "bump", run))

        await tasks.toggleRun(fixture.project, "bump", run)
        #expect(reads.count == 1 && tasks.isOpen(fixture.project, "bump", run))
        #expect(tasks.detail(fixture.project, "bump", run) == detail)
        // Another task's run at the same time, and another run of this task, are not it.
        #expect(tasks.detail(fixture.project, "other", run) == nil)
        var later = run
        later.started = run.started.addingTimeInterval(60)
        #expect(tasks.detail(fixture.project, "bump", later) == nil && !tasks.isOpen(fixture.project, "bump", later))

        await tasks.refresh(fixture.project)
        #expect(reads.count == 1, "a refresh while it is open reads nothing")
        await tasks.toggleRun(fixture.project, "bump", run)
        #expect(!tasks.isOpen(fixture.project, "bump", run) && reads.count == 1, "closing reads nothing")
        await tasks.toggleRun(fixture.project, "bump", run)
        #expect(reads.count == 2, "opening again reads again: the run may have gone on")
    }

    @Test func theFactsSayWhatTheRunDid() {
        let facts = RunDetailFacts.make(detail, running: false)
        #expect(
            facts.facts.map { "\($0.label): \($0.value)" } == [
                "took: 1m 30s", "cost: $0.75", "setup: passed (3s)", "check: failed (5s)", "refused: 2 tool calls",
                "agent said: the final answer",
            ])
        #expect(facts.checkTail == ["boom"] && facts.note == nil)
        var one = detail
        one.denied = 1
        #expect(RunDetailFacts.make(one, running: false).facts.contains { $0.value == "1 tool call" })
    }

    @Test func anUnknownCostAndMissingPiecesAreSaidNotInvented() {
        var unknown = detail
        unknown.costUSD = nil
        #expect(RunDetailFacts.make(unknown, running: false).facts.contains { $0.label == "cost" && $0.value == "unknown" })
        let none = RunDetailFacts.make(TaskRunDetail(source: .noThread, duration: 45), running: false)
        #expect(none.facts.map(\.label) == ["took"] && none.facts[0].value == "45s", "no cost is shown for a run with no thread")
        #expect(none.note?.contains("started no thread") == true)
        let gone = RunDetailFacts.make(TaskRunDetail(source: .removed, duration: 45), running: false)
        #expect(gone.note?.contains("thread was removed") == true)
    }

    @Test func aRunStillGoingShowsWhatIsKnown() {
        let going = RunDetailFacts.make(TaskRunDetail(source: .read, duration: nil, costUSD: nil), running: true)
        #expect(going.facts.first == RunDetailFacts.Fact(label: "took", value: "still going"))
        #expect(!going.facts.contains { $0.label == "check" || $0.label == "agent said" })
    }
}
