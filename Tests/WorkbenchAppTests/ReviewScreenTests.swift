import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var runOptions: [RunOptions] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    func add(_ options: RunOptions) { lock.withLock { runOptions.append(options) } }
    var log: [String] { lock.withLock { items } }
    var options: [RunOptions] { lock.withLock { runOptions } }
}

@MainActor private var keptFixtures: [AppFixture] = []

@MainActor @Suite struct ReviewScreenTests {
    private let goalProblem = "line 3: broken"

    private func file(_ path: String, add: Int? = 1, del: Int? = 0, binary: Bool = false) -> FileChange {
        FileChange(
            path: path, oldPath: nil, status: .modified, additions: add, deletions: del, isBinary: binary,
            isUntracked: false)
    }

    private func report(
        _ fixture: AppFixture, diff: ReviewReport.Diff? = nil, problem: String? = nil
    ) throws -> ReviewReport {
        let project = fixture.project
        let events = try EventLogReader.read(at: project.eventsURL("t1")).events
        let state = ThreadState.derive(from: events, id: "t1")
        let goal = try GoalFile.parse(String(contentsOf: project.goalURL("t1"), encoding: .utf8)).goal
        let summary = DiffSummary(base: "abc", files: [file("a.swift", add: 3, del: 1)], truncated: false, totalFiles: 1)
        let shown = diff ?? .summary(summary)
        return ReviewReport(
            state: state, title: goal.title, criteria: problem == nil ? goal.criteria : [], approval: "approved",
            goalProblem: problem, diff: shown, threadDirectory: project.threadDirectory("t1"))
    }

    private func ended(_ result: String = "succeeded", proofs: [String]? = nil) async throws -> AppFixture {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true, proofs: proofs)
        try fixture.turn("t1", 1, result: result, cost: 1.5)
        return fixture
    }

    @Test func theHeadlineHasTheTurnAndTheFilesAndLines() async throws {
        let fixture = try await ended()
        let model = ReviewModel.derive(try report(fixture))
        #expect(model.headline == "Turn 1 succeeded" && model.totals == "1 file · +3 −1")
        #expect(model.files.map(\.text) == ["M  a.swift  +3 −1"] && model.canDecide)
    }

    @Test func aBinaryFileAndMissingCountsAreSaidNotInvented() async throws {
        let fixture = try await ended()
        let diff = ReviewReport.Diff.summary(
            DiffSummary(
                base: "abc", files: [file("a.png", add: nil, del: nil, binary: true), file("b", add: nil, del: nil)],
                truncated: false, totalFiles: 2))
        let model = ReviewModel.derive(try report(fixture, diff: diff))
        #expect(model.files.map(\.text) == ["M  a.png  binary", "M  b  counts unavailable"])
    }

    @Test func criteriaCarryCoresLabelsAndAProofWithNoCheckIsForYou() async throws {
        let fixture = try await ended(proofs: ["`swift test` passes", "screenshot: invoice-list"])
        let model = ReviewModel.derive(try report(fixture))
        #expect(model.criteria.map(\.id) == ["c1", "c2"])
        #expect(model.criteria.allSatisfy(\.forYou) && model.undecided == 2)
        #expect(model.criteria[1].label == "✘ missing")
        #expect(model.criteriaSummary.contains("1 missing") && model.criteriaSummary.contains("check did not run"))
    }

    @Test func aGoalThatDoesNotParseHasNoCriteriaAndSaysWhy() async throws {
        let fixture = try await ended()
        let model = ReviewModel.derive(try report(fixture, problem: goalProblem))
        #expect(model.criteria.isEmpty && model.goalProblem == goalProblem)
    }

    @Test func anUnreadableDiffSaysWhyAndBlocksAccept() async throws {
        let fixture = try await ended()
        let model = ReviewModel.derive(try report(fixture, diff: .unavailable(reason: "the worktree no longer exists")))
        #expect(model.diffProblem == "Diff unavailable: the worktree no longer exists" && !model.canDecide)
    }

    @Test(arguments: ["stopped", "timed_out", "failed", "interrupted"])
    func aTurnThatDidNotFinishIsStillReviewable(result: String) async throws {
        let fixture = try await ended(result)
        let model = ReviewModel.derive(try report(fixture))
        #expect(model.canDecide && model.result == result)
    }

    @Test func aTurnStillOpenCannotBeDecided() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.append("t1", .turnStarted, turn: 1, data: ["session_id": "s1"])
        #expect(!ReviewModel.derive(try report(fixture)).canDecide)
    }

    @Test func noCheckSaysNoneRanAndAPassedOneNamesItsCommand() async throws {
        let fixture = try await ended()
        #expect(ReviewModel.derive(try report(fixture)).check == "none ran")
        try fixture.append(
            "t1", .checkRan, turn: 1, data: ["result": "passed", "exit_code": 0, "command": "swift test"])
        #expect(ReviewModel.derive(try report(fixture)).check == "passed (exit 0) · swift test")
    }

    // MARK: The decisions

    private func store(
        _ recorder: Recorder, accept: AcceptPlan? = nil, acceptError: Error? = nil
    ) async throws -> ProjectStore {
        let fixture = try await ended()
        keptFixtures.append(fixture)
        let reported = try report(fixture)
        let actions = GoalActions(
            makeRun: { _, _, options in
                recorder.add(options)
                return RunHandle(run: {}, stop: {})
            },
            loadReview: { _, _ in reported },
            acceptPlan: { _, _ in accept ?? Self.plan },
            accept: { _, _, shown, message in
                recorder.add("accept \(shown == (accept ?? Self.plan)) \(message ?? "-")")
                if let acceptError { throw acceptError }
                return AcceptResult(branch: "b", commit: "c", committedNow: true)
            },
            discardPlan: { _, _ in
                DiscardPlan(id: "t1", worktree: nil, branch: nil, diff: .unavailable(reason: "x"), commits: [])
            },
            discard: { _, _, _ in recorder.add("discard") },
            patch: { _, _, path in .text("patch of \(path)") })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    private nonisolated static let plan = AcceptPlan(
        id: "t1", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1",
        diff: .unavailable(reason: "x"), hasPendingChanges: true, commits: [], check: nil, openWork: false,
        snapshot: "s", defaultMessage: "feat: it")

    @Test func theReviewLoadsOnlyWhileATurnAwaitsOne() async throws {
        let store = try await store(Recorder())
        #expect(store.review?.canDecide == true)
    }

    @Test func acceptPassesTheShownPlanAndTheMessage() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        await store.prepareAccept()
        #expect(store.pendingAccept == Self.plan)
        await store.confirmAccept(message: "my message")
        #expect(recorder.log == ["accept true my message"] && store.pendingAccept == nil)
    }

    @Test func aPlanThatChangedIsRefusedWithCoresMessageAndCommitsNothing() async throws {
        let recorder = Recorder()
        let store = try await store(recorder, acceptError: ThreadServiceError.changedSinceAcceptShown)
        await store.prepareAccept()
        await store.confirmAccept(message: nil)
        #expect(store.actionError != nil)
        #expect(store.pendingAccept == nil)
    }

    @Test func discardPassesTheShownPlan() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        await store.prepareDiscard()
        #expect(store.pendingDiscard != nil)
        await store.confirmDiscard()
        #expect(recorder.log == ["discard"] && store.pendingDiscard == nil)
    }

    @Test func discardForwardsTheExactPlanItWasShown() async throws {
        let seen = Recorder()
        let fixture = try await ended()
        keptFixtures.append(fixture)
        let reported = try report(fixture)
        let shown = DiscardPlan(
            id: "t1", worktree: nil, branch: "workbench/t1", diff: .unavailable(reason: "x"), commits: ["a b"])
        let actions = GoalActions(
            loadReview: { _, _ in reported }, discardPlan: { _, _ in shown },
            discard: { _, _, plan in seen.add("discard \(plan == shown)") })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        await store.prepareDiscard()
        await store.confirmDiscard()
        #expect(seen.log == ["discard true"])
    }

    @Test func deniedCallsAreGroupedByWhatWasDeniedWithACount() async throws {
        let fixture = try await ended()
        let denial: JSONValue = [["tool": "Bash", "input": "git push"], ["tool": "Bash", "input": "git push"]]
        let refused: JSONValue = ["provider": "claude", "type": "permission_denied", "tool": "Bash"]
        try fixture.append("t1", .agentActivity, turn: 1, data: refused)
        try fixture.append("t1", .agentActivity, turn: 1, data: refused)
        try fixture.append(
            "t1", .turnEnded, turn: 1, data: ["result": "succeeded", "permission_denials": 2, "denials": denial])
        let model = ReviewModel.derive(try report(fixture))
        #expect(model.denied.count == 1 && model.denied[0].count == 2 && model.denied[0].text == "Bash(git push)")
    }

    @Test func aFailedCriterionIsFlaggedFailedNotForYou() async throws {
        let fixture = try await ended(proofs: ["`swift test` passes"])
        try fixture.append("t1", .checkRan, turn: 1, data: ["result": "failed", "exit_code": 1, "command": "swift test"])
        let model = ReviewModel.derive(try report(fixture))
        #expect(model.criteria[0].failed && !model.criteria[0].forYou && model.assessed == "1 of 1 assessed")
    }

    @Test func refreshReadsTheReviewAgain() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        #expect(store.review != nil)
        await store.refreshReview()
        #expect(store.review?.canDecide == true)
    }

    @Test func cancellingADecisionDoesNothing() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        await store.prepareAccept()
        store.cancelAccept()
        await store.prepareDiscard()
        store.cancelDiscard()
        #expect(recorder.log.isEmpty && store.pendingAccept == nil && store.pendingDiscard == nil)
    }

    @Test func sendBackNeedsANoteAndAPositiveBudget() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        store.sendBack(note: "  \n", budget: "")
        #expect(store.actionError == "Say what to change: a note is required." && recorder.options.isEmpty)
        for bad in ["0", "-1", "12.5oops", "abc"] {
            store.sendBack(note: "fix it", budget: bad)
            #expect(store.actionError?.hasPrefix("The budget must be a positive number") == true)
        }
        #expect(recorder.options.isEmpty)
    }

    @Test func sendBackStartsATurnWithTheNoteAndTheOneTurnBudget() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        store.sendBack(note: "handle the empty list", budget: "2.5")
        let options = try #require(recorder.options.first)
        #expect(options.feedback == "handle the empty list" && options.budgetOverride == Decimal(string: "2.5"))
        #expect(store.runningHere)
    }

    @Test func viewDiffReadsOneFilesPatchFromCore() async throws {
        let store = try await store(Recorder())
        #expect(await store.patchText("a.swift") == "patch of a.swift")
    }
}
