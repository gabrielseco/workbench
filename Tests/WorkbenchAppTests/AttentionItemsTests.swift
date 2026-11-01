import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct AttentionItemsTests {
    static func entries(git: Bool = false) async throws -> (AppFixture, [TaskEntry]) {
        let fixture = try await AppFixture(git: git)
        try await AppScenario.tasks.build(in: fixture)
        return (fixture, try TasksReader.entries(fixture.project, now: Date(timeIntervalSince1970: 1_793_500_000)))
    }

    static func thread(_ text: String, since: Int, commit: String? = nil, title: String? = "Paginate") -> ThreadAttention {
        ThreadAttention(id: "t1", title: title, attention: .needsYou(AttentionReason(text: text, since: since, commit: commit)))
    }

    static func run(_ outcome: TaskOutcome?, at seconds: TimeInterval) -> TaskHistory.Run {
        TaskHistory.Run(
            started: Date(timeIntervalSince1970: seconds),
            ended: outcome == nil ? nil : Date(timeIntervalSince1970: seconds + 60), pullRequest: nil, trigger: "tick",
            outcome: outcome, reason: outcome == .failed ? "the check failed" : nil, units: [], thread: nil)
    }

    /// A loaded, approved task with these runs, newest first.
    static func task(_ entry: TaskEntry, runs: [TaskHistory.Run], approval: TaskApproval.State = .approved) -> TaskEntry {
        var copy = entry
        copy.summary.problem = nil
        copy.summary.approval = approval
        copy.runs = runs
        return copy
    }

    @Test func whatCounts() async throws {
        let (_, entries) = try await Self.entries()
        let thread = Self.thread("Review · turn 2 done", since: 7)
        let items = AttentionItems.derive(thread: thread, tasks: entries)
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(items.first?.id == "thread:t1:7", "the thread comes first")
        #expect(byId["thread:t1:7"]?.tone == .needsYou)
        // failed, and the newest decisive run of an interrupted task whose newest run is still going
        let failed = try #require(items.first { $0.route == .task("sync-fixtures") })
        #expect(failed.tone == .broken && failed.reason.hasPrefix("failed: the check failed"))
        #expect(failed.id.hasPrefix("task:sync-fixtures:") && failed.at != nil)
        let interrupted = try #require(items.first { $0.route == .task("nightly-lint") })
        #expect(interrupted.reason.hasPrefix("interrupted"))
        // an approval that is stale now
        let stale = try #require(items.first { $0.route == .task("update-docs") })
        #expect(stale.tone == .needsYou && stale.id.contains(":stale:"))
        // CI on the same pull request head is one identity, another head is another
        let ci = Self.thread("CI failed: unit", since: 9, commit: "abc", title: nil)
        #expect(AttentionItems.derive(thread: ci, tasks: []).first?.id == "thread:t1:9:abc")
        #expect(AttentionItems.derive(thread: ci, tasks: []).first?.title == "t1")
    }

    @Test func whatNeverCounts() async throws {
        let (_, entries) = try await Self.entries()
        let base = try #require(entries.first { $0.id == "weekly-report" })
        func items(_ runs: [TaskHistory.Run]) -> [AttentionItem] {
            AttentionItems.derive(thread: nil, tasks: [Self.task(base, runs: runs)])
        }
        // ends well, or is only a skip, or is still going with nothing broken before it
        #expect(items([Self.run(.prOpened, at: 100)]).isEmpty)
        #expect(items([Self.run(.reported, at: 100)]).isEmpty)
        #expect(items([Self.run(.nothingPending, at: 100)]).isEmpty)
        #expect(items([Self.run(.nothingToDo, at: 100)]).isEmpty)
        #expect(items([Self.run(.skippedProjectBusy, at: 100)]).isEmpty)
        #expect(items([Self.run(.skippedAlreadyRunning, at: 100)]).isEmpty)
        #expect(items([Self.run(.skippedTooManyOpen, at: 100)]).isEmpty)
        #expect(items([Self.run(nil, at: 100)]).isEmpty)
        #expect(items([Self.run(.staleApproval, at: 100)]).isEmpty, "the approval itself is what counts, not the note")
        #expect(items([]).isEmpty)
        // a task that does not load is the timer card's problem; a task not approved yet is not a decision waiting
        var broken = try #require(entries.first { $0.id == "broken-task" })
        broken.runs = [Self.run(.failed, at: 100)]
        #expect(AttentionItems.derive(thread: nil, tasks: [broken]).isEmpty)
        let fresh = Self.task(base, runs: [], approval: .never)
        #expect(AttentionItems.derive(thread: nil, tasks: [fresh]).isEmpty)
        // a thread that is working, or has nothing to say
        let working = ThreadAttention(id: "t", title: nil, attention: .working)
        #expect(AttentionItems.derive(thread: working, tasks: []).isEmpty)
    }

    @Test func clearing() async throws {
        let (_, entries) = try await Self.entries()
        let base = try #require(entries.first { $0.id == "weekly-report" })
        func items(_ runs: [TaskHistory.Run], approval: TaskApproval.State = .approved) -> [AttentionItem] {
            AttentionItems.derive(thread: nil, tasks: [Self.task(base, runs: runs, approval: approval)])
        }
        // a skip after a failure does not hide it (the failed thread is left for you, so the next ticks skip)
        #expect(items([Self.run(.skippedProjectBusy, at: 300), Self.run(.failed, at: 200)]).count == 1)
        // a run that ends well after it clears it
        #expect(items([Self.run(.prOpened, at: 300), Self.run(.failed, at: 200)]).isEmpty)
        #expect(items([Self.run(.nothingPending, at: 300), Self.run(.budgetExceeded, at: 200)]).isEmpty)
        // a run going now does not clear it
        #expect(items([Self.run(nil, at: 300), Self.run(.failed, at: 200)]).count == 1)
        // approved again: the stale item is gone, and it is a new identity when edited once more later
        let stale = items([], approval: .stale)
        #expect(stale.count == 1)
        #expect(items([], approval: .approved).isEmpty)
        var later = Self.task(base, runs: [], approval: .stale)
        later.approvedAt = Date(timeIntervalSince1970: 5_000)
        var earlier = later
        earlier.approvedAt = Date(timeIntervalSince1970: 1_000)
        let ids = [earlier, later].flatMap { AttentionItems.derive(thread: nil, tasks: [$0]) }.map(\.id)
        #expect(Set(ids).count == 2)
    }
}
