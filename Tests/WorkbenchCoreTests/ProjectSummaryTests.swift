import Foundation
import Testing

@testable import WorkbenchCore

/// P26 slice 3: what a project holds, read from its logs alone, for the project rail's counts.
@Suite struct ProjectSummaryTests {
    private func project() -> Project { Project(root: Scratch.url("summary").resolvingSymlinksInPath()) }

    private struct Step {
        var kind: EventKind
        var turn = 0
        var data: JSONValue = [:]
    }

    /// A thread's log from events written the way a run writes them.
    private func thread(_ project: Project, _ id: String, _ steps: [Step]) async throws {
        let log = try EventLogWriter.open(at: project.eventsURL(id))
        try await log.append(.threadCreated, data: [:])
        for step in steps { try await log.append(step.kind, turn: step.turn, data: step.data) }
        await log.close()
    }

    private let approved = Step(kind: .goalApproved, data: ["hash": "h1"])
    private let started = Step(kind: .turnStarted, turn: 1, data: ["session_id": "s1"])
    private let ended = Step(kind: .turnEnded, turn: 1, data: ["result": "succeeded"])
    private func decision(_ word: String) -> Step { Step(kind: .reviewDecision, data: ["decision": .string(word)]) }

    @Test func eachKindOfThreadCountsOnceAndAFinishedOneNotAtAll() async throws {
        let project = project()
        try await thread(project, "g-2026-11-08-needs", [approved, started, ended])  // a turn ended, no decision: needs you
        try await thread(project, "g-2026-11-08-working", [approved, started])  // a turn is open
        try await thread(project, "g-2026-11-08-accepted", [approved, started, ended, decision("accepted")])
        try await thread(project, "g-2026-11-08-discarded", [approved, decision("discarded")])
        try await thread(project, "g-2026-11-08-draft", [])

        #expect(ProjectSummaryLoader.read(project: project) == ProjectSummary(needsYou: 1, failed: 0, running: 1))
    }

    @Test func aLogThatCannotBeReadIsFailedNotZero() async throws {
        let project = project()
        let url = project.eventsURL("g-2026-11-08-broken")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "this is not an event\nnor is this\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(ProjectSummaryLoader.read(project: project)?.failed == 1)
    }

    @Test func aProjectWithNoThreadsOrNoFolderHoldsNothing() {
        #expect(ProjectSummaryLoader.read(project: project()) == ProjectSummary())
        let gone = Project(root: URL(fileURLWithPath: "/no/such/project"))
        #expect(ProjectSummaryLoader.read(project: gone) == ProjectSummary(), "nothing is read, nothing is thrown")
    }

    @Test func aPollOfAnUnchangedProjectReplaysNothingAndAChangedThreadOnlyItself() async throws {
        let project = project()
        for index in 0..<4 { try await thread(project, "g-2026-11-08-t\(index)", [approved, started, ended]) }
        let cache = ProjectSummaryLoader.Cache()

        #expect(ProjectSummaryLoader.read(project: project, cache: cache)?.needsYou == 4)
        #expect(cache.replays == 4, "the first read replays each thread once")
        #expect(ProjectSummaryLoader.read(project: project, cache: cache)?.needsYou == 4)
        #expect(cache.replays == 4, "nothing changed: nothing was replayed")

        let log = try EventLogWriter.open(at: project.eventsURL("g-2026-11-08-t2"))
        try await log.append(.reviewDecision, data: ["decision": "accepted"])
        await log.close()
        #expect(ProjectSummaryLoader.read(project: project, cache: cache)?.needsYou == 3)
        #expect(cache.replays == 5, "only the thread that changed")
    }

    @Test func aThreadThatWasRemovedLeavesTheCache() async throws {
        let project = project()
        try await thread(project, "g-2026-11-08-a", [approved, started, ended])
        let cache = ProjectSummaryLoader.Cache()
        #expect(ProjectSummaryLoader.read(project: project, cache: cache)?.needsYou == 1)
        try FileManager.default.removeItem(at: project.threadDirectory("g-2026-11-08-a"))
        #expect(ProjectSummaryLoader.read(project: project, cache: cache) == ProjectSummary())
    }

    @Test func onlyTheNewestThreadsAreReadSoAHugeProjectCostsABoundedPoll() async throws {
        let project = project()
        try await thread(project, "g-2000-01-01-oldest", [approved, started, ended])  // sorts first: the oldest
        for index in 0..<ProjectSummaryLoader.maxThreads {
            try await thread(project, String(format: "g-2026-11-08-n%03d", index), [])
        }
        #expect(ProjectSummaryLoader.read(project: project)?.needsYou == 0, "the oldest is past the bound")
    }

    @Test func theSummaryAndTheListShareOneRuleForAThreadsMark() {
        #expect(ThreadActivity.chat(state: ThreadState.derive(from: [], id: "c")) == .idle)
        let sum = ProjectSummary(needsYou: 1, failed: 2, running: 3) + ProjectSummary(needsYou: 4)
        #expect(sum == ProjectSummary(needsYou: 5, failed: 2, running: 3))
    }

    @Test func aThreadsFolderThatCannotBeListedIsNotZero() async throws {
        let project = project()
        try FileManager.default.createDirectory(at: project.workbenchDirectory, withIntermediateDirectories: true)
        // A file where the folder should be: it exists and cannot be listed, as a volume that went away does not answer.
        try "x".write(to: project.threadsDirectory, atomically: true, encoding: .utf8)
        #expect(ProjectSummaryLoader.read(project: project) == nil, "the caller keeps the last count")
    }

    @Test func aChatWithAValidStartAndACorruptTailIsRedNotGrey() async throws {
        let project = project()
        let id = "g-2026-11-08-chat"
        try await thread(project, id, [Step(kind: .chatMessage, data: ["role": "user", "text": "hello"])])
        let handle = try FileHandle(forWritingTo: project.eventsURL(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ this is not json\n{ nor this\n".utf8))
        try handle.close()
        #expect(ProjectSummaryLoader.read(project: project)?.failed == 1)
    }
}
