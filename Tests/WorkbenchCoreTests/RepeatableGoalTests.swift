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

@Suite(.processGate) struct RepeatableGoalTests {
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

    @Test func aLongNameStillGetsAValidSuffixOnARepeat() async throws {
        let (_, service) = try await fixture(suffixes: ["beef"])
        let day = try await service.newThread(name: "x")
        try await service.abandon(id: day)
        let prefix = String(day.dropLast(1))  // "g-<day>-"
        let name = String(repeating: "n", count: 96 - prefix.count)  // a plain id of 96 characters
        let first = try await service.newThread(name: name)
        #expect(first.count == 96)
        try await service.abandon(id: first)
        let second = try await service.newThread(name: name)
        #expect(SafeNames.isThreadID(second))
        #expect(second.hasSuffix("-beef"))
        #expect(second != first)
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

@Suite(.processGate) struct CopyGoalTests {
    @Test func theRequestCriteriaAndOutOfScopeComeInAsADraft() async throws {
        let (fx, service) = try await fixture(suffixes: ["cafe"])
        let url = try write(goalFile(), in: fx)
        let id = try await service.newThread(name: "copy", body: try ThreadService.goalCopy(copying: url).body)
        let copy = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8))
        #expect(copy.goal.request == "Make it work.")
        #expect(copy.goal.criteria.map(\.id) == ["c1"])
        #expect(copy.goal.criteria.first?.proof == "swift test")
        #expect(copy.goal.outOfScope == ["Everything else."])
        #expect(copy.goal.id == id)
        #expect(copy.goal.approval == .draft)
        #expect(copy.goal.base == "main")
    }

    @Test func theBudgetTimeoutAndModelAreCarried() async throws {
        let (fx, service) = try await fixture(suffixes: ["cafe"])
        let text = goalFile().replacingOccurrences(of: "turn_timeout_min: 30", with: "turn_timeout_min: 45\nmodel: sonnet")
        let copy = try ThreadService.goalCopy(copying: try write(text, in: fx))
        #expect(copy.settings == GoalSettings(budgetUSD: 7, turnTimeoutMin: 45, model: "sonnet"))
        let id = try await service.newThread(name: "copy", body: copy.body, settings: copy.settings)
        let goal = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8)).goal
        #expect(goal.budgetUSD == 7)
        #expect(goal.turnTimeoutMin == 45)
        #expect(goal.model == "sonnet")
    }

    @Test func keysTheFileDoesNotGiveKeepTheDefaults() async throws {
        let (fx, service) = try await fixture(suffixes: ["cafe"])
        let text =
            "---\ntitle: Only a title\n---\n\n## Request\n\nMake it work.\n\n## Criteria\n\n"
            + "- [c1] It works.\n  - proof: swift test\n"
        let copy = try ThreadService.goalCopy(copying: try write(text, in: fx))
        #expect(copy.settings == GoalSettings())
        #expect(copy.ignoredKeys == ["title"])
        let id = try await service.newThread(name: "copy", body: copy.body, settings: copy.settings)
        let goal = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8)).goal
        #expect(goal.budgetUSD == Config.defaultBudgetUSD)
        #expect(goal.turnTimeoutMin == 30)
        #expect(goal.model == nil)
    }

    @Test func theKeysThatBelongToTheSourceThreadAreNamed() async throws {
        let (fx, _) = try await fixture(suffixes: ["cafe"])
        let approved = try GoalFile.parse(goalFile()).approving()
        let copy = try ThreadService.goalCopy(copying: try write(approved.text, in: fx))
        #expect(copy.ignoredKeys == ["id", "title", "status", "base", "approved_at", "approved_hash"])
    }

    @Test(arguments: [
        ("budget_usd: 7.00", "budget_usd: -3", "'budget_usd'"),
        ("turn_timeout_min: 30", "turn_timeout_min: 0", "'turn_timeout_min'"),
        ("turn_timeout_min: 30", "turn_timeout_min: 30\nmodel: -rm", "'model'"),
    ])
    func aBadCarriedValueIsRefusedNamingTheKey(old: String, new: String, key: String) async throws {
        let (fx, _) = try await fixture(suffixes: ["cafe"])
        let url = try write(goalFile().replacingOccurrences(of: old, with: new), in: fx)
        do {
            _ = try ThreadService.goalCopy(copying: url)
            Issue.record("a bad \(key) was accepted")
        } catch let error as ThreadServiceError {
            guard case .copyValueInvalid(let message) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(message.contains(key))
        }
    }

    @Test func aGoalApprovedElsewhereComesInAsADraft() async throws {
        let (fx, service) = try await fixture(suffixes: ["cafe"])
        let approved = try GoalFile.parse(goalFile()).approving()
        let url = try write(approved.text, in: fx)
        #expect(approved.goal.approval == .approved)
        let id = try await service.newThread(name: "copy", body: try ThreadService.goalCopy(copying: url).body)
        let text = try String(contentsOf: fx.project.goalURL(id), encoding: .utf8)
        #expect(!text.contains("approved_hash"))
        #expect(try GoalFile.parse(text).goal.approval == .draft)
    }

    @Test func aMissingFileIsRefusedBeforeAnythingIsCreated() async throws {
        let (fx, service) = try await fixture(suffixes: ["cafe"])
        let url = fx.repo.appendingPathComponent("nope.md")
        #expect(throws: ThreadServiceError.copySourceMissing(url.path)) {
            _ = try ThreadService.goalCopy(copying: url)
        }
        #expect(ThreadStore(project: fx.project).threadIDs().isEmpty)
        _ = service
    }

    @Test func aFileWithNoCriteriaIsRefused() async throws {
        let (fx, _) = try await fixture(suffixes: ["cafe"])
        let url = try write(goalFile(criteria: ""), in: fx)
        #expect(throws: ThreadServiceError.self) { _ = try ThreadService.goalCopy(copying: url) }
    }

    @Test func theCopiedCriterionKeepsItsText() async throws {
        let (fx, _) = try await fixture(suffixes: ["cafe"])
        let body = try ThreadService.goalCopy(copying: try write(goalFile(), in: fx)).body
        #expect(body.criteria == [GoalBody.Criterion(id: "c1", text: "It works.", proof: "swift test")])
    }

    @Test func aFifoIsRefusedWithoutBlocking() async throws {
        let (fx, _) = try await fixture(suffixes: ["cafe"])
        let url = fx.repo.appendingPathComponent("fifo.md")
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(throws: ThreadServiceError.copySourceMissing(url.path)) {
            _ = try ThreadService.goalCopy(copying: url)
        }
    }

    @Test func aHugeFileIsRefused() async throws {
        let (fx, _) = try await fixture(suffixes: ["cafe"])
        let url = try write(String(repeating: "x", count: ThreadService.copySourceLimit + 1), in: fx)
        #expect(throws: ThreadServiceError.copySourceTooLarge(url.path)) {
            _ = try ThreadService.goalCopy(copying: url)
        }
    }
}
