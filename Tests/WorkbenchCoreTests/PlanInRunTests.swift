import Foundation
import Testing

@testable import WorkbenchCore

private let editedPlan = "## Approach\n\nA person rewrote this plan.\n"

private func advisories(_ box: NoticeBox) -> [String] {
    box.all.compactMap { if case .advisory(let text) = $0 { text } else { nil } }
}

private func started(_ p: Planned) -> [Event] { p.events.filter { $0.kind == .turnStarted } }

private func prompt(_ p: Planned, turn: Int) throws -> String {
    try String(contentsOf: p.fx.project.promptURL(p.id, turn: turn), encoding: .utf8)
}

private func planText(_ p: Planned, _ ref: String) throws -> String {
    try String(contentsOf: p.fx.project.threadDirectory(p.id).appendingPathComponent(ref), encoding: .utf8)
}

private func makePlan(_ p: Planned, again: Bool = false) async throws {
    _ = try await p.fx.service.plan(id: p.id, config: p.config, again: again, environment: try p.answering(aPlan))
}

private func changeGoal(_ p: Planned) async throws {
    let url = p.fx.project.goalURL(p.id)
    try (try String(contentsOf: url, encoding: .utf8) + "\n- one more thing\n").write(to: url, atomically: true, encoding: .utf8)
    try await p.fx.service.approve(id: p.id)
}

@Suite struct PlanPromptTests {
    private func goal() throws -> Goal {
        try GoalFile.parse(
            """
            ---
            id: g
            title: Greet
            status: draft
            base: main
            budget_usd: 1
            turn_timeout_min: 5
            ---

            ## Request

            Add a greeting.

            ## Criteria

            - [c1] a.txt says hello
              - proof: cat a.txt

            ## Out of scope

            - other files
            """
        ).goal
    }

    private func plan(source: PlanSource = .generated, plannedAt: String? = nil) -> PlanForRun {
        PlanForRun(text: "Do the thing.\n", source: source, sha256: "s", bytes: 14, plannedAt: plannedAt)
    }

    @Test func thePlanIsAdviceAfterTheOutOfScopeList() throws {
        let text = PromptBuilder.firstPrompt(goal: try goal(), checkCommand: nil, plan: plan())
        let outOfScope = try #require(text.range(of: "## Out of scope"))
        let section = try #require(text.range(of: "## Plan"))
        #expect(outOfScope.lowerBound < section.lowerBound)
        #expect(text.contains("Do the thing."))
        #expect(text.contains("the criteria and the out-of-scope list win wherever they disagree"))
        #expect(text.contains("say so in your summary"))
        #expect(!text.contains("a person then edited it") && !text.contains("It was written at commit"))
    }

    @Test func anEditedPlanAndAMovedBaseAreSaid() throws {
        let text = PromptBuilder.firstPrompt(
            goal: try goal(), checkCommand: nil, plan: plan(source: .edited, plannedAt: "0123456789abcdef"))
        #expect(text.contains("a person then edited it"))
        #expect(text.contains("`0123456789ab`") && text.contains("different one"))
    }

    @Test func withoutAPlanThePromptIsAsBefore() throws {
        let text = PromptBuilder.firstPrompt(goal: try goal(), checkCommand: nil)
        #expect(!text.contains("## Plan"))
    }
}

@Suite struct PlanInRunTests {
    @Test func theFirstPromptCarriesThePlanAndTheLogSaysSo() async throws {
        let p = try await planned()
        try await makePlan(p)
        let notices = NoticeBox()
        _ = try await p.fx.runner(p.id, notices: notices).run(p.fx.options())

        #expect(try prompt(p, turn: 1).contains("Add a greeting to a.txt.\n\n## Files"))
        let first = try #require(started(p).first)
        let plan = try #require(first.data["plan"])
        let stored = try planText(p, "plans/plan-1.md")
        #expect(plan["sha256"]?.stringValue == Plan.sha256(stored) && plan["bytes"]?.intValue == stored.utf8.count)
        #expect(plan["source"] == "generated")
        #expect(advisories(notices).allSatisfy { !$0.contains("plan") })
    }

    @Test func aFollowUpTurnCarriesNoPlanAndOmitsTheKey() async throws {
        let p = try await planned()
        try await makePlan(p)
        _ = try await p.fx.runner(p.id).run(p.fx.options())
        _ = try await p.fx.runner(p.id).run(p.fx.options(feedback: "also add a line"))
        #expect(!(try prompt(p, turn: 2)).contains("## Plan"))
        let second = try #require(started(p).last)
        #expect(second.turn == 2 && second.data["plan"] == nil)
    }

    @Test func noPlanMeansPlanNullAndNothingElseChanges() async throws {
        let p = try await planned()
        _ = try await p.fx.runner(p.id).run(p.fx.options())
        let first = try #require(started(p).first)
        #expect(first.data["plan"] == .null, "the key is there and says no plan")
        #expect(!(try prompt(p, turn: 1)).contains("## Plan"))
    }

    @Test func noPlanLeavesAnExistingPlanOut() async throws {
        let p = try await planned()
        try await makePlan(p)
        var options = p.fx.options()
        options.noPlan = true
        _ = try await p.fx.runner(p.id).run(options)
        #expect(!(try prompt(p, turn: 1)).contains("## Plan"))
        #expect(started(p).first?.data["plan"] == .null)
    }

    @Test func aPlanForAnEarlierVersionOfTheGoalIsLeftOutAndSaid() async throws {
        let p = try await planned()
        try await makePlan(p)
        try await changeGoal(p)
        let notices = NoticeBox()
        _ = try await p.fx.runner(p.id, notices: notices).run(p.fx.options())
        #expect(!(try prompt(p, turn: 1)).contains("## Plan"))
        #expect(started(p).first?.data["plan"] == .null)
        #expect(advisories(notices).contains { $0.contains("earlier version of the goal") })
    }

    @Test(arguments: ["changed", "missing"])
    func aPlanFileThatIsNotWhatTheLogRecordedIsLeftOut(how: String) async throws {
        let p = try await planned()
        try await makePlan(p)
        let file = p.fx.project.threadDirectory(p.id).appendingPathComponent("plans/plan-1.md")
        if how == "changed" { try "tampered".write(to: file, atomically: true, encoding: .utf8) } else {
            try FileManager.default.removeItem(at: file)
        }
        let notices = NoticeBox()
        _ = try await p.fx.runner(p.id, notices: notices).run(p.fx.options())
        #expect(started(p).first?.data["plan"] == .null)
        #expect(!(try prompt(p, turn: 1)).contains("tampered"))
        #expect(advisories(notices).contains { $0.contains("plans/plan-1.md") && $0.contains(how) })
    }

    @Test func aWorktreeCutFromAnotherCommitThanThePlanWasMadeAtSaysSo() async throws {
        let p = try await planned()
        try await makePlan(p)
        try "more\n".write(to: p.fx.repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await p.fx.git.run(["add", "-A"], in: p.fx.repo)
        _ = try await p.fx.git.run(["commit", "-q", "-m", "second"], in: p.fx.repo)
        _ = try await p.fx.runner(p.id).run(p.fx.options())
        #expect(try prompt(p, turn: 1).contains("this worktree starts from a different one"))
    }

    @Test func aLaterFailedPlanDoesNotHideTheGoodOne() async throws {
        let p = try await planned()
        try await makePlan(p)
        _ = try await p.fx.service.plan(
            id: p.id, config: p.config, again: true, environment: try p.answering(aPlan, "exit=1"))
        _ = try await p.fx.runner(p.id).run(p.fx.options())
        #expect(try prompt(p, turn: 1).contains("## Plan"))
    }
}

@Suite struct PlanEditTests {
    @Test func aDraftIsTheLatestPlanAndApplyingItMakesAnEditTheRunUses() async throws {
        let p = try await planned()
        try await makePlan(p)
        let service = p.fx.service
        let draft = try await service.planDraft(id: p.id)
        #expect(try String(contentsOf: draft, encoding: .utf8) == (try planText(p, "plans/plan-1.md")))
        try editedPlan.write(to: draft, atomically: true, encoding: .utf8)

        let result = try await service.planEdit(id: p.id, text: try service.planDraftText(id: p.id))
        #expect(result.ref == "plans/plan-2.md" && !result.truncated)
        let event = try #require(p.events.last)
        #expect(event.kind == .planEdited && event.data["plan_ref"] == "plans/plan-2.md")
        #expect(event.data["from_sha256"]?.stringValue?.count == 64 && event.data["goal_hash"] != nil)
        #expect(event.data["base_commit"] != nil && event.data["sha256"]?.stringValue == Plan.sha256(editedPlan + ""))
        #expect(p.events.filter { $0.kind == .planEnded }.count == 1, "the generated plan stays in the log")
        #expect(p.events.filter { $0.kind == .turnStarted }.isEmpty, "not a numbered turn")
        #expect(!FileManager.default.fileExists(atPath: draft.path), "the draft is used up")
        #expect(try p.fx.contents(p.id).isHealthy)

        _ = try await p.fx.runner(p.id).run(p.fx.options())
        #expect(try prompt(p, turn: 1).contains("A person rewrote this plan."))
        #expect(try prompt(p, turn: 1).contains("a person then edited it"))
        #expect(started(p).first?.data["plan"]?["source"] == "edited")
    }

    @Test func aPlanCanBeGivenWithoutOneBeingMadeFirst() async throws {
        let p = try await planned()
        let result = try await p.fx.service.planEdit(id: p.id, text: editedPlan)
        #expect(result.ref == "plans/plan-1.md")
        let event = try #require(p.events.last)
        #expect(event.data["from_sha256"] == .null && event.data["base_commit"] != nil)
    }

    @Test func theNewestOfAnEditAndARegenerateWins() async throws {
        let p = try await planned()
        try await makePlan(p)
        try await p.fx.service.planEdit(id: p.id, text: editedPlan)
        try await makePlan(p, again: true)
        #expect(PlanLookup.latest(in: p.events)?.source == .generated)
        try await p.fx.service.planEdit(id: p.id, text: editedPlan + "\nAnd a second edit.\n")
        let latest = try #require(PlanLookup.latest(in: p.events))
        #expect(latest.source == .edited && latest.ref == "plans/plan-4.md")
    }

    @Test func theEditIsBoundedAndScrubbedLikeAGeneratedPlan() async throws {
        let p = try await planned()
        let text = "Edit /Users/dev/secret/x.swift https://bob:hunter22@host/r\n" + String(repeating: "word ", count: 6000)
        let result = try await p.fx.service.planEdit(id: p.id, text: text)
        #expect(result.truncated)
        let stored = try planText(p, result.ref)
        #expect(stored.hasSuffix(Plan.cutMarker) && !stored.contains("/Users/dev") && !stored.contains("hunter22"))
    }

    @Test func refusalsRecordNothing() async throws {
        let p = try await planned()
        let service = p.fx.service
        func refusal(_ body: () async throws -> Void) async -> PlanRefusal? {
            do { try await body() } catch let error as PlanRefusal { return error } catch { return nil }
            return nil
        }
        #expect(await refusal { _ = try await service.planDraft(id: p.id) } == .noPlanToEdit)
        #expect(await refusal { _ = try service.planDraftText(id: p.id) } == .noDraft)
        #expect(await refusal { try await service.planEdit(id: p.id, text: "  \n ") } == .emptyEdit)

        try await service.planEdit(id: p.id, text: editedPlan)
        #expect(await refusal { try await service.planEdit(id: p.id, text: editedPlan) } == .unchangedEdit)

        #expect(p.events.filter { $0.kind == .planEdited }.count == 1, "only the one edit that was accepted")
        #expect(try p.fx.contents(p.id).isHealthy)
    }

    @Test func aDraftOrChangedGoalCannotBeEditedAndABusyThreadIsRefused() async throws {
        let fx = try await RunnerFixture()
        let draft = try await fx.service.newThread(name: "draft", base: "main")
        do {
            try await fx.service.planEdit(id: draft, text: editedPlan)
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .goalNotApproved(.draft)) }

        let p = try await planned()
        try await changeGoalWithoutApproving(p)
        do {
            try await p.fx.service.planEdit(id: p.id, text: editedPlan)
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .goalNotApproved(.stale)) }

        let q = try await planned()
        let held = try EventLogWriter.open(at: q.fx.project.eventsURL(q.id))
        do {
            try await q.fx.service.planEdit(id: q.id, text: editedPlan)
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .busy) }
        await held.close()
    }

    @Test func aBusyThreadAndAChangedGoalRefuseADraftAndAnOversizedDraftIsNotRead() async throws {
        let p = try await planned()
        try await makePlan(p)
        let held = try EventLogWriter.open(at: p.fx.project.eventsURL(p.id))
        do {
            _ = try await p.fx.service.planDraft(id: p.id)
            Issue.record("expected the thread to be busy")
        } catch let error as PlanRefusal { #expect(error == .busy) }
        await held.close()
        #expect(!FileManager.default.fileExists(atPath: p.fx.service.planDraftURL(p.id).path), "nothing was overwritten")

        let draft = try await p.fx.service.planDraft(id: p.id)
        try String(repeating: "x", count: ThreadService.editInputLimit + 1).write(to: draft, atomically: true, encoding: .utf8)
        do {
            _ = try p.fx.service.planDraftText(id: p.id)
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal {
            if case .fileUnreadable = error {} else { Issue.record("\(error)") }
        }
        #expect(p.events.filter { $0.kind == .planEdited }.isEmpty)

        try await changeGoalWithoutApproving(p)
        do {
            _ = try await p.fx.service.planDraft(id: p.id)
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .goalNotApproved(.stale)) }
    }

    @Test func anEditWhoseBaseCannotBeReadIsNotRecorded() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread("ghost", base: "no-such-branch")
        do {
            try await fx.service.planEdit(id: id, text: editedPlan)
            Issue.record("expected a refusal")
        } catch let error as PlanRefusal { #expect(error == .baseUnknown) }
        #expect(try fx.events(id).allSatisfy { $0.kind != .planEdited })
    }

    @Test func aRegeneratedPlanAfterAnEditIsTheOneTheCoderGets() async throws {
        let p = try await planned()
        try await makePlan(p)
        try await p.fx.service.planEdit(id: p.id, text: editedPlan)
        try await makePlan(p, again: true)
        _ = try await p.fx.runner(p.id).run(p.fx.options())
        let text = try prompt(p, turn: 1)
        #expect(text.contains("Add a greeting to a.txt.") && !text.contains("A person rewrote this plan."))
        #expect(started(p).first?.data["plan"]?["source"] == "generated")
    }

    @Test func showSaysWhoWroteItAndWhetherItStillFitsTheGoal() async throws {
        let p = try await planned()
        #expect(p.fx.service.planShow(id: p.id) == nil)
        try await makePlan(p)
        var view = try #require(p.fx.service.planShow(id: p.id))
        #expect(view.plan.source == .generated && view.belongsToGoal == true && view.text == aPlan && view.costUSD == 0.001)
        try await changeGoal(p)
        view = try #require(p.fx.service.planShow(id: p.id))
        #expect(view.belongsToGoal == false, "made for an earlier version of the goal")
        try "tampered".write(
            to: p.fx.project.threadDirectory(p.id).appendingPathComponent("plans/plan-1.md"), atomically: true, encoding: .utf8)
        view = try #require(p.fx.service.planShow(id: p.id))
        #expect(view.text == nil && view.problem?.contains("changed since it was recorded") == true)
    }
}

@Suite struct PlanDisplayTests {
    @Test func theStateKeepsThePlanApartFromTheTurnsAndKnowsWhenItIsStale() async throws {
        let p = try await planned()
        try await makePlan(p)
        try await makePlan(p, again: true)
        _ = try await p.fx.runner(p.id).run(p.fx.options())
        var state = ThreadState.derive(from: p.events, id: p.id)
        #expect(state.planCostUSD == 0.002 && state.totalCostUSD != state.planCostUSD)
        #expect(state.currentPlan?.source == .generated && state.currentPlan?.goalHash == state.approvedGoalHash)
        #expect(ReviewReport.planLine(for: state).hasPrefix("plan:      generated"))
        #expect(!ReviewReport.planLine(for: state).contains("stale"))
        #expect(ReviewReport.costText(state).contains("(turns $") && ReviewReport.costText(state).contains("plan $0.0020"))

        try await changeGoal(p)
        state = ThreadState.derive(from: p.events, id: p.id)
        #expect(ReviewReport.planLine(for: state).contains("stale: made for an earlier version of the goal"))
    }

    @Test func noPlanAFailedPlanAndAnEditAreEachSaid() async throws {
        let p = try await planned()
        var state = ThreadState.derive(from: p.events, id: p.id)
        #expect(ReviewReport.planLine(for: state) == "plan:      none")
        #expect(ReviewReport.costText(state) == String(format: "$%.4f", 0))

        _ = try await p.fx.service.plan(id: p.id, config: p.config, environment: try p.answering(aPlan, "exit=1"))
        state = ThreadState.derive(from: p.events, id: p.id)
        #expect(ReviewReport.planLine(for: state).hasPrefix("plan:      none (the last attempt failed: "))

        try await p.fx.service.planEdit(id: p.id, text: editedPlan)
        state = ThreadState.derive(from: p.events, id: p.id)
        #expect(ReviewReport.planLine(for: state) == "plan:      edited")
        #expect(state.plan?.ok == true && state.currentPlan?.costUSD == nil)
    }

    @Test func theModelIsReadFromTheLoggedCommand() async throws {
        let p = try await planned(extraConfig: "plan_model = \"opus\"\n")
        try await makePlan(p)
        let state = ThreadState.derive(from: p.events, id: p.id)
        #expect(state.currentPlan?.model == "opus")
        #expect(ReviewReport.planLine(for: state).contains("(opus)"))
    }
}

private func changeGoalWithoutApproving(_ p: Planned) async throws {
    let url = p.fx.project.goalURL(p.id)
    try (try String(contentsOf: url, encoding: .utf8) + "\n- one more thing\n").write(to: url, atomically: true, encoding: .utf8)
}
