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

    @Test func theStepsStillDueAreShownWithoutTheDecisionItself() async throws {
        let fixture = try await ended()
        var shown = try report(fixture)
        shown.nextSteps = [
            NextStep(name: "judge", command: "workbench judge t1", why: "no judge has run for turn 1 (advisory)", kind: .judge),
            NextStep(name: "design", command: "workbench review-stage design t1", why: "the change touches Sources/**"),
            NextStep(
                name: "accept", command: "workbench accept t1 -m \"<message>\"", why: "or send-back or discard", kind: .decision),
        ]
        let model = ReviewModel.derive(shown)
        #expect(model.due.map(\.command) == ["workbench judge t1", "workbench review-stage design t1"], "Accept is the button")
        #expect(model.due[1].command == "workbench review-stage design t1")
        shown.nextSteps = [NextStep(name: "ship", command: "workbench ship t1", why: "accepted", kind: .decision)]
        #expect(ReviewModel.derive(shown).due.isEmpty)
        // Stages are named by the project: one called accept or judge is advice like any other, with an id of its own.
        shown.nextSteps = [
            NextStep(name: "judge", command: "workbench judge t1", why: "w", kind: .judge),
            NextStep(name: "judge", command: "workbench review-stage judge t1", why: "w"),
            NextStep(name: "accept", command: "workbench review-stage accept t1", why: "w"),
        ]
        let named = ReviewModel.derive(shown).due
        #expect(named.count == 3 && Set(named.map(\.id)).count == 3)
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
        _ recorder: Recorder, accept: AcceptPlan? = nil, acceptError: Error? = nil, runError: Error? = nil,
        makeRunError: Error? = nil, syncBase: (@Sendable (Project, String) async throws -> BaseSyncResult)? = nil
    ) async throws -> ProjectStore {
        let fixture = try await ended()
        keptFixtures.append(fixture)
        let reported = try report(fixture)
        let actions = GoalActions(
            makeRun: { _, _, options in
                recorder.add(options)
                if let makeRunError { throw makeRunError }
                return RunHandle(run: { if let runError { throw runError } }, stop: {})
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
            patch: { _, _, path in .text("patch of \(path)") },
            syncBase: syncBase ?? { _, _ in throw GoalActions.Unset() })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    private nonisolated static func movement(behind: Int = 2, overlapping: [String] = ["a.swift"]) -> BaseMovement {
        let tip = String(repeating: "b", count: 40)
        return BaseMovement(base: "main", tip: tip, behind: behind, overlapping: overlapping, overlapTruncated: false)
    }

    @Test func theReviewSaysTheBaseMovedOnlyWhileTheThreadAwaitsADecision() async throws {
        let fixture = try await ended()
        var shown = try report(fixture)
        #expect(ReviewModel.derive(shown).baseMoved == nil, "nothing moved: nothing is said")
        shown.baseMovement = Self.movement(behind: 0, overlapping: [])
        #expect(ReviewModel.derive(shown).baseMoved == nil)
        shown.baseMovement = Self.movement()
        let moved = try #require(ReviewModel.derive(shown).baseMoved)
        #expect(moved.files == ["a.swift"] && moved.line == Self.movement().line)

        try fixture.decide("t1", "accepted")
        var decided = try report(fixture)
        decided.baseMovement = Self.movement()
        #expect(ReviewModel.derive(decided).baseMoved == nil, "an accepted thread has nothing to bring the base into")
    }

    @Test func bringingTheBaseInStartsATurnFromWhatTheMergeFound() async throws {
        let recorder = Recorder()
        let found = BaseSyncResult.conflicts(Self.movement(), files: ["a.swift"], savedWork: nil)
        let store = try await store(recorder, syncBase: { _, _ in found })
        await store.bringBaseIn()
        let options = try #require(recorder.options.last)
        #expect(options.feedback == SyncPrompt.note(for: found), "the turn starts from the note core wrote")
        #expect(store.actionError == nil)
    }

    @Test func aBaseThatHasNotMovedStartsNoTurn() async throws {
        let recorder = Recorder()
        let store = try await store(recorder, syncBase: { _, _ in .upToDate(Self.movement(behind: 0, overlapping: [])) })
        await store.bringBaseIn()
        #expect(recorder.options.isEmpty && store.notice != nil)
    }

    @Test func aRefusedSyncSaysSoAndStartsNoTurn() async throws {
        struct Refused: Error, CustomStringConvertible { var description: String { "a run holds this thread" } }
        let recorder = Recorder()
        let store = try await store(recorder, syncBase: { _, _ in throw Refused() })
        await store.bringBaseIn()
        #expect(recorder.options.isEmpty && store.actionError == "a run holds this thread")
    }

    private nonisolated static let plan = AcceptPlan(
        id: "t1", worktree: URL(fileURLWithPath: "/tmp/w"), branch: "workbench/t1",
        diff: .unavailable(reason: "x"), hasPendingChanges: true, commits: [], check: nil, openWork: false,
        snapshot: "s", defaultMessage: "feat: it")

    @Test func theReviewLoadsOnlyWhileATurnAwaitsOne() async throws {
        let store = try await store(Recorder())
        #expect(store.review?.canDecide == true)
    }

    /// One click accepts core's plan with the default message, with no confirmation in between, and says what it made.
    @Test func acceptWorkImmediately() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        await store.accept()
        #expect(recorder.log == ["accept true -"])
        #expect(store.notice == "Accepted: c on b" && store.actionError == nil && store.busy == nil && !store.deciding)
    }

    @Test func aPlanThatChangedIsRefusedWithCoresMessageAndCommitsNothing() async throws {
        let recorder = Recorder()
        let store = try await store(recorder, acceptError: ThreadServiceError.changedSinceAcceptShown)
        await store.accept()
        #expect(store.actionError != nil && store.notice == nil && !store.deciding)
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

    @Test func aPlanThatArrivesAfterLeavingTheProjectIsNotAccepted() async throws {
        let fixture = try await ended()
        keptFixtures.append(fixture)
        let reported = try report(fixture)
        let (release, recorder) = (Release(), Recorder())
        let actions = GoalActions(
            loadReview: { _, _ in reported }, acceptPlan: { _, _ in await release.wait(); return Self.plan },
            accept: { _, _, _, _ in
                recorder.add("accept")
                return AcceptResult(branch: "b", commit: "c", committedNow: true)
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        let accepting = Task { await store.accept() }
        try await Task.sleep(for: .milliseconds(100))
        let other = try await AppFixture()
        keptFixtures.append(other)
        #expect(await store.open(other.root))
        await release.open()
        _ = await accepting.value
        #expect(recorder.log.isEmpty && store.notice == nil)
    }

    @Test func aTruncatedDiffSaysTheLineCountsCoverTheListedFiles() async throws {
        let fixture = try await ended()
        let diff = ReviewReport.Diff.summary(
            DiffSummary(base: "abc", files: [file("a", add: 5, del: 1)], truncated: true, totalFiles: 300))
        let model = ReviewModel.derive(try report(fixture, diff: diff))
        #expect(model.totals == "300 files · +5 −1 in the 1 listed")
    }

    @Test func cancellingADiscardDoesNothing() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        await store.prepareDiscard()
        store.cancelDiscard()
        #expect(recorder.log.isEmpty && store.pendingDiscard == nil)
    }

    @Test func sendBackNeedsANote() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        for blank in ["", "  \n"] {
            store.guidanceNote = blank
            store.sendGuidance()
            #expect(store.actionError == "Say what to change: a note is required.")
        }
        #expect(recorder.options.isEmpty)
    }

    @Test func sendBackStartsATurnWithTheNote() async throws {
        let recorder = Recorder()
        let store = try await store(recorder)
        store.guidanceNote = "handle the empty list"
        store.sendGuidance()
        let options = try #require(recorder.options.first)
        #expect(options.feedback == "handle the empty list" && options.budgetOverride == nil)
        // The run here ends at once, before any poll could see the turn begin: the spent note must still be gone.
        for _ in 0..<100 where !store.guidanceNote.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.guidanceNote.isEmpty)
    }

    @Test func aRunThatWillNotStartKeepsTheNote() async throws {
        struct Refused: Error {}
        for (runError, makeRunError) in [(Refused?.none, Refused()), (Refused(), nil)] as [(Refused?, Refused?)] {
            let store = try await store(Recorder(), runError: runError, makeRunError: makeRunError)
            store.guidanceNote = "handle the empty list"
            store.sendGuidance()
            // The refusal of an asynchronous start arrives a moment later.
            for _ in 0..<100 where store.actionError == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(store.guidanceNote == "handle the empty list")
            #expect(store.actionError?.hasPrefix("The run did not start") == true)
        }
    }

    @Test func theNoteIsPerThreadAndGoneWhenTheProjectChanges() async throws {
        let store = try await store(Recorder())
        let thread = try #require(store.currentThread)
        store.guidanceNote = "mine"
        #expect(store.guidanceNotes[thread] == "mine")
        store.guidanceNotes["other"] = "theirs"
        #expect(store.guidanceNote == "mine", "another thread's text is not shown here")
        store.clearGuidance()
        #expect(store.guidanceNote.isEmpty && store.guidanceNotes.isEmpty)
    }

    @Test func viewDiffReadsOneFilesPatchFromCore() async throws {
        let store = try await store(Recorder())
        #expect(await store.patchText("a.swift") == "patch of a.swift")
    }
}

private actor Release {
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
