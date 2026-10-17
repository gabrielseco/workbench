import Foundation
import Testing

@testable import WorkbenchCore

/// A suffix generator that hands out a fixed list, then repeats the last one.
private final class Suffixes: @unchecked Sendable {
    private let lock = NSLock()
    private var rest: [String]

    init(_ values: [String]) { rest = values }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return rest.count > 1 ? rest.removeFirst() : rest[0]
    }
}

private func fixture(suffixes: [String]) async throws -> (RunnerFixture, ThreadService) {
    let fx = try await RunnerFixture()
    let source = Suffixes(suffixes)
    return (fx, ThreadService(project: fx.project, git: fx.git, idSuffix: { source.next() }))
}

private func goalFile(criteria: String = "- [c1] It works.\n  - proof: swift test", status: String = "draft") -> String {
    """
    ---
    id: g-2026-01-01-source
    title: Source
    status: \(status)
    base: main
    budget_usd: 7.00
    turn_timeout_min: 30
    ---

    ## Request

    Make it work.

    ## Criteria

    \(criteria)

    ## Out of scope

    - Everything else.
    """
}

private func write(_ text: String, in fx: RunnerFixture, named name: String = "source.md") throws -> URL {
    let url = fx.repo.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Starts and abandons a thread called `again`, then deletes its directory and leaves a branch under its id,
/// the way a discarded thread can leave one. Returns the id.
private func leaveOnlyABranch(_ fx: RunnerFixture, _ service: ThreadService) async throws -> String {
    let id = try await service.newThread(name: "again")
    try await service.abandon(id: id)
    try FileManager.default.removeItem(at: fx.project.threadDirectory(id))
    _ = try await fx.git.run(["branch", WorktreeManager.branch(for: id)], in: fx.repo)
    return id
}

@Suite struct RepeatableGoalTests {
    @Test func theFirstRunKeepsThePlainName() async throws {
        let (_, service) = try await fixture(suffixes: ["aaaa"])
        let id = try await service.newThread(name: "again")
        #expect(id.hasSuffix("-again"))
        #expect(!id.contains("aaaa"))
    }

    @Test func theSameNameTwiceInOneDayGetsASuffix() async throws {
        let (_, service) = try await fixture(suffixes: ["beef"])
        let first = try await service.newThread(name: "again")
        try await service.abandon(id: first)
        let second = try await service.newThread(name: "again")
        #expect(second == first + "-beef")
        #expect(SafeNames.isThreadID(second))
    }

    @Test func aLeftoverBranchMakesTheSuffixClashOnceThenTheRetryIsFree() async throws {
        let (fx, service) = try await fixture(suffixes: ["dead", "feed"])
        let plain = try await leaveOnlyABranch(fx, service)
        // The plain id has no thread, only a branch; the first suffix has a branch too.
        _ = try await fx.git.run(["branch", WorktreeManager.branch(for: plain + "-dead")], in: fx.repo)
        let id = try await service.newThread(name: "again")
        #expect(id == plain + "-feed")
    }

    @Test func itGivesUpWhenEverySuffixIsTaken() async throws {
        let (fx, service) = try await fixture(suffixes: ["dead"])
        let plain = try await leaveOnlyABranch(fx, service)
        _ = try await fx.git.run(["branch", WorktreeManager.branch(for: plain + "-dead")], in: fx.repo)
        await #expect(throws: ThreadServiceError.noFreeID(plain)) {
            _ = try await service.newThread(name: "again")
        }
    }
}

@Suite struct CopyGoalTests {
    @Test func theRequestCriteriaAndOutOfScopeComeInAsADraft() async throws {
        let (fx, service) = try await fixture(suffixes: ["cafe"])
        let url = try write(goalFile(), in: fx)
        let id = try await service.newThread(name: "copy", body: try ThreadService.goalBody(copying: url))
        let copy = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8))
        #expect(copy.goal.request == "Make it work.")
        #expect(copy.goal.criteria.map(\.id) == ["c1"])
        #expect(copy.goal.criteria.first?.proof == "swift test")
        #expect(copy.goal.outOfScope == ["Everything else."])
        #expect(copy.goal.id == id)
        #expect(copy.goal.approval == .draft)
        // Not the source's budget.
        #expect(copy.goal.budgetUSD != 7)
    }

    @Test func aGoalApprovedElsewhereComesInAsADraft() async throws {
        let (fx, service) = try await fixture(suffixes: ["cafe"])
        let approved = try GoalFile.parse(goalFile()).approving()
        let url = try write(approved.text, in: fx)
        #expect(approved.goal.approval == .approved)
        let id = try await service.newThread(name: "copy", body: try ThreadService.goalBody(copying: url))
        let text = try String(contentsOf: fx.project.goalURL(id), encoding: .utf8)
        #expect(!text.contains("approved_hash"))
        #expect(try GoalFile.parse(text).goal.approval == .draft)
    }

    @Test func aMissingFileIsRefusedBeforeAnythingIsCreated() async throws {
        let (fx, service) = try await fixture(suffixes: ["cafe"])
        let url = fx.repo.appendingPathComponent("nope.md")
        #expect(throws: ThreadServiceError.copySourceMissing(url.path)) {
            _ = try ThreadService.goalBody(copying: url)
        }
        #expect(ThreadStore(project: fx.project).threadIDs().isEmpty)
        _ = service
    }

    @Test func aFileWithNoCriteriaIsRefused() async throws {
        let (fx, _) = try await fixture(suffixes: ["cafe"])
        let url = try write(goalFile(criteria: ""), in: fx)
        #expect(throws: ThreadServiceError.self) { _ = try ThreadService.goalBody(copying: url) }
    }

    @Test func aHugeFileIsRefused() async throws {
        let (fx, _) = try await fixture(suffixes: ["cafe"])
        let url = try write(String(repeating: "x", count: ThreadService.copySourceLimit + 1), in: fx)
        #expect(throws: ThreadServiceError.copySourceTooLarge(url.path)) {
            _ = try ThreadService.goalBody(copying: url)
        }
    }
}
