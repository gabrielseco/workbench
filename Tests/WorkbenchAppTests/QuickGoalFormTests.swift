import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptQuickFixtures: [AppFixture] = []

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

/// The New goal card's two kinds of goal, and what the goal and review screens say about a goal without criteria.
@MainActor @Suite struct QuickGoalFormTests {
    private func store(_ calls: Calls, quick: Error? = nil) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        keptQuickFixtures.append(fixture)
        let actions = GoalActions(
            draftGoal: { _, name, request, _, _ in
                calls.add("draft \(name)|\(request)")
                return GoalDraftResult(id: "g-\(name)", provider: .claude)
            },
            quickGoal: { _, name, request, attachments in
                if let quick { throw quick }
                calls.add("quick \(name)|\(request)|\(attachments.map(\.lastPathComponent).joined(separator: ","))")
                return "g-\(name)"
            })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return store
    }

    @Test func theCardOpensOnAQuickGoal() {
        let form = NewGoalForm()
        #expect(form.mode == .quick && form.isEmpty)
        #expect(NewGoalForm.Mode.allCases == [.quick, .advanced], "Advanced is offered beside it")
    }

    @Test func createMakesAQuickGoalFromTheTextAsTypedWithNoDrafter() async throws {
        let calls = Calls()
        let store = try await store(calls)
        var form = NewGoalForm()
        form.request = "  Make the header blue.\n\nand bold \n"
        #expect(await store.createGoal(form, attachments: [URL(fileURLWithPath: "/staged/1.png")]))
        #expect(calls.all == ["quick make-the-header-blue|Make the header blue.\n\nand bold|1.png"])
        #expect(!store.drafting && store.actionError == nil)
    }

    @Test func switchingToAdvancedKeepsTheTextAndHasTheGoalAgentDraftIt() async throws {
        let calls = Calls()
        let store = try await store(calls)
        var form = NewGoalForm()
        form.request = "Make the header blue."
        form.mode = .advanced
        #expect(form.request == "Make the header blue.")
        #expect(await store.createGoal(form))
        form.mode = .quick
        #expect(form.request == "Make the header blue.", "and back again")
        #expect(calls.all == ["draft make-the-header-blue|Make the header blue."])
    }

    @Test func aRefusedQuickGoalSaysWhyAndKeepsTheCardUp() async throws {
        let calls = Calls()
        let store = try await store(calls, quick: GoalActions.RefusalText("the request is empty"))
        var form = NewGoalForm()
        form.request = "x"
        #expect(await store.createGoal(form) == false)
        #expect(store.actionError == "the request is empty" && !store.goalAgentOff && !store.drafting)
    }

    @Test func theGoalScreenSaysWhyTheJudgeAndVerifierAreOffForAGoalWithoutCriteria() async throws {
        let fixture = try await AppFixture()
        keptQuickFixtures.append(fixture)
        try await fixture.addThread("t1")
        let text = """
            ---
            id: t1
            title: Blue header
            base: main
            budget_usd: 5
            turn_timeout_min: 30
            quick: true
            ---

            ## Request

            Make the header blue.

            ## Criteria

            """
        try text.write(to: fixture.project.goalURL("t1"), atomically: true, encoding: .utf8)
        let model = await GoalModel.load(project: fixture.project, thread: "t1") { _, _ in true }
        #expect(model.blockers.isEmpty && model.rows.isEmpty && model.quick && model.canApprove)
        let judge = try #require(model.steps.first { $0.name == "judge" })
        #expect(judge.unavailable == Goal.noCriteriaJudge)
    }

    @Test func theReviewScreenSaysWhyThereIsNoJudge() {
        var report = ReviewReport(
            state: ThreadState.derive(from: [], id: "t1"), title: "T", criteria: [], approval: "approved", goalProblem: nil,
            diff: .unavailable(reason: "x"))
        report.unavailableSteps = [ReviewReport.UnavailableStep(name: "judge", why: Goal.noCriteriaJudge)]
        #expect(ReviewModel.derive(report).unavailable == ["Judge not available: \(Goal.noCriteriaJudge)."])
    }
}
