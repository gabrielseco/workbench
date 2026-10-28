import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct FinishedThreadTests {
    private func snapshot(_ scenario: AppScenario) async throws -> ThreadSnapshot {
        let fixture = try await AppFixture(git: false)
        try await scenario.build(in: fixture)
        guard case .thread(let shown) = ProjectLoader.load(project: fixture.project).screen else {
            throw FinishedError.notAThread
        }
        return shown
    }

    @Test func eachWayAThreadEndsIsSaidInWords() async throws {
        #expect(try await snapshot(.cleaned).finishedText == "Cleaned: the branch was removed.")
        #expect(try await snapshot(.prOpen).finishedText == "Shipped as PR #482.")
        #expect(try await snapshot(.needsYou).finishedText == nil)
        #expect(try await snapshot(.draft).finishedText == nil)
    }

    @Test func aDiscardedAndAnAcceptedThreadAreNamedNotCalledOpen() async throws {
        let fixture = try await AppFixture(git: false)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "discarded")
        guard case .thread(let discarded) = ProjectLoader.load(project: fixture.project).screen else { return }
        #expect(discarded.finishedText == "Discarded: the worktree and branch were removed.")

        let other = try await AppFixture(git: false)
        try await other.addThread("t1", approved: true)
        try other.turn("t1", 1)
        try other.decide("t1", "accepted")
        guard case .thread(let accepted) = ProjectLoader.load(project: other.project).screen else { return }
        #expect(accepted.finishedText == "Accepted, not shipped yet.")
    }

    @Test func aNewGoalIsOfferedOnlyWhenNothingOfTheThreadIsLeftToShip() async throws {
        #expect(try await snapshot(.discarded).newGoalHint == nil)
        #expect(try await snapshot(.cleaned).newGoalHint == nil)
        #expect(try await snapshot(.prOpen).newGoalHint?.hasPrefix("Clean this thread once its pull request is merged") == true)
        let fixture = try await AppFixture(git: false)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "accepted")
        guard case .thread(let accepted) = ProjectLoader.load(project: fixture.project).screen else { return }
        #expect(accepted.newGoalHint?.contains("Ship this thread first") == true)
        let abandoned = try await AppFixture(git: false)
        try await abandoned.addThread("t1", approved: true)
        try abandoned.turn("t1", 1)
        try abandoned.decide("t1", "abandoned")
        guard case .thread(let gone) = ProjectLoader.load(project: abandoned.project).screen else { return }
        #expect(gone.newGoalHint == nil)
    }

    @Test func reviewIsNotNextOnceThereIsADecision() {
        #expect(RunModel.nextLine(decided: false) == "Review comes next.")
        #expect(RunModel.nextLine(decided: true) == nil)
    }

    @Test func aNewGoalCanBeStartedFromAFinishedThread() async throws {
        let made = Names()
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "discarded")
        let store = ProjectStore(
            preferences: MemoryPreferences(projectPath: nil), actions: GoalActions(newThread: { _, name in made.add(name) }))
        #expect(await store.open(fixture.root))
        await store.newGoal(name: "next")
        #expect(made.all == ["next"] && store.actionError == nil)
    }

    @Test func coresRefusalWhileAnotherThreadIsActiveIsShown() async throws {
        struct Busy: Error, CustomStringConvertible { var description: String { "thread t2 is active" } }
        let fixture = try await AppFixture()
        keptFixtures.append(fixture)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        try fixture.decide("t1", "discarded")
        let store = ProjectStore(
            preferences: MemoryPreferences(projectPath: nil), actions: GoalActions(newThread: { _, _ in throw Busy() }))
        #expect(await store.open(fixture.root))
        await store.newGoal(name: "next")
        #expect(store.actionError == "thread t2 is active")
    }
}

private enum FinishedError: Error { case notAThread }

private final class Names: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}
