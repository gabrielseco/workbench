import Foundation
import Testing

@testable import WorkbenchCore

/// A brief request, with a blank line, an indented line and spacing a drafter would have rewritten.
private let brief = "Make the header blue.\n\n  and keep   the logo where it is"

private func goal(_ fx: RunnerFixture, _ id: String) throws -> GoalFile {
    try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8))
}

private func firstPrompt(_ fx: RunnerFixture, _ id: String) throws -> String {
    try String(contentsOf: fx.project.promptURL(id, turn: 1), encoding: .utf8)
}

/// The prompt's `## ` headings, in order: which sections went in.
private func headings(_ prompt: String) -> [String] {
    prompt.split(separator: "\n").filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
}

@Suite(.processGate) struct QuickGoalTests {
    @Test func createAndRunWithoutCriteria() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.service.newQuickGoal(name: "header", request: "  \(brief)\n\n", base: "main")
        let file = try goal(fx, id)
        #expect(file.goal.quick && file.goal.criteria.isEmpty && file.goal.outOfScope.isEmpty)
        #expect(file.goal.request == brief, "the words are kept as written, only trimmed at the ends")
        #expect(file.goal.title == "Make the header blue.")
        #expect(file.goal.approval == .draft, "it is reviewed and approved like any goal")
        #expect(try fx.kinds(id) == ["thread.created", "goal.saved"], "nothing was drafted, spent or approved")

        try await fx.service.approve(id: id)
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.result == .succeeded)
        let prompt = try firstPrompt(fx, id)
        #expect(prompt.contains("## Request\n\n\(brief)\n"), "the coding turn gets the request as the person wrote it")
        #expect(!headings(prompt).contains("Criteria"), "no empty criteria section")
    }

    @Test func aRequestTheGoalFileCannotHoldAsWrittenIsRefusedAndNothingIsMade() async throws {
        let fx = try await RunnerFixture()
        for (request, refusal) in [
            ("   \n", QuickGoalRefusal.emptyRequest),
            ("Fix it\n## Details", .heading("## Details")),
            (String(repeating: "x", count: GoalDraft.requestLimit + 1), .requestTooLong),
        ] {
            await #expect(throws: refusal) { try await fx.service.newQuickGoal(name: "x", request: request, base: "main") }
        }
        let threads = (try? FileManager.default.contentsOfDirectory(atPath: fx.project.threadsDirectory.path)) ?? []
        #expect(threads.isEmpty)
    }

    @Test func lifecycleWithoutCriteria() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.service.newQuickGoal(name: "header", request: brief, base: "main")
        try await fx.service.approve(id: id)
        _ = try await fx.runner(id).run(fx.options())

        let review = await ReviewLoader(project: fx.project, git: fx.git).load(id: id)
        #expect(review.goalProblem == nil && review.criteria.isEmpty)
        #expect(review.status == .awaitingReview)
        #expect(review.nextSteps.map(\.name) == ["accept"], "the decision is next, with no judge before it")

        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "one\nblue\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await fx.service.accept(id: id, message: "feat: blue header")
        let after = await ReviewLoader(project: fx.project, git: fx.git).load(id: id)
        #expect(after.state.decision == "accepted")
        #expect(after.nextSteps.map(\.name) == ["ship"])
    }

    @Test func criterionDependentFeaturesWithoutCriteria() async throws {
        let fx = try await RunnerFixture(extraConfig: "")
        let id = try await fx.service.newQuickGoal(name: "header", request: brief, base: "main")
        try await fx.service.approve(id: id)
        _ = try await fx.runner(id).run(fx.options())
        var config = try Config.load(from: fx.project.configURL)
        let before = try fx.kinds(id)

        // The judge is refused with the reason, before anything is started, spent or logged.
        await #expect(throws: JudgeRefusal.noCriteria) {
            _ = try await fx.service.judge(id: id, config: config, environment: ["PATH": "/usr/bin:/bin"])
        }
        #expect("\(JudgeRefusal.noCriteria)".contains(Goal.noCriteriaJudge))
        #expect(try fx.kinds(id) == before, "a refusal writes nothing")

        // `[review] auto` skips it and says why.
        config.review.auto = ["judge"]
        let advice = await fx.service.runAutoAdvice(id: id, config: config)
        #expect(advice == [AutoAdviceResult(name: "judge", outcome: .skipped(Goal.noCriteriaJudge))])
        #expect(try fx.kinds(id) == before)

        // `review` and `next` leave it out of what is due, and say why it is not there.
        let review = await ReviewLoader(project: fx.project, git: fx.git).load(id: id)
        #expect(!review.nextSteps.contains { $0.kind == .judge })
        #expect(review.unavailableSteps.map(\.name) == ["judge"], "the verifier works from the request")
        #expect(review.unavailableSteps.last?.why == Goal.noCriteriaJudge)
        #expect(review.render().contains("Judge      not available: \(Goal.noCriteriaJudge)"))

        // A criterion added to the quick goal brings the judge back.
        let file = try goal(fx, id)
        let edited = try GoalEditor.apply(.addCriterion(text: "The header is blue.", proof: "screenshot: header"), to: file)
        #expect(edited.goal.unavailable("judge") == nil)
        #expect(try GoalEditor.apply(.removeCriterion(id: "c1"), to: edited).goal.criteria.isEmpty, "and can go again")
    }

    @Test func theVerifierIsToldTheRequestAndNoCriteriaForAQuickGoal() throws {
        let skill = VerifierSkill(path: "v.md", text: "SKILL TEXT", sha256: "", bytes: 10, truncated: false)
        let dir = URL(fileURLWithPath: "/tmp/proof")
        let quick = try GoalFile.parse(
            "---\nid: g\ntitle: T\nbase: main\nbudget_usd: 1\nturn_timeout_min: 30\nquick: true\n---\n\n"
                + "## Request\n\nMake the header blue.\n").goal
        let text = Verifier.prompt(skill: skill, goal: quick, proofDirectory: dir, threadID: "g", goalPath: "/g.md")
        // The request and the skill reach it, and the section for criteria says there are none instead of being empty.
        #expect(text.contains("Make the header blue.") && text.contains("SKILL TEXT"))
        let sections = text.components(separatedBy: "\n## ").map { $0.prefix { $0 != "\n" } }
        #expect(sections.filter { $0 == "Criteria" }.count == 1)
        #expect(!text.contains("\n  - proof:"), "no criterion is invented")

        let ordinary = try GoalFile.parse(
            "---\nid: g\ntitle: T\nbase: main\nbudget_usd: 1\nturn_timeout_min: 30\n---\n\n## Request\n\nDo it.\n\n"
                + "## Criteria\n\n- [c1] Done.\n  - proof: screenshot: done\n").goal
        let withCriterion = Verifier.prompt(skill: skill, goal: ordinary, proofDirectory: dir, threadID: "g", goalPath: "/g.md")
        #expect(withCriterion.contains("- [c1] Done.") && withCriterion.contains("proof: screenshot: done"))
        #expect(!withCriterion.contains("None: this is a quick goal"))
    }

    @Test func aStageNamedLikeABuiltInStepStillRunsWithoutCriteria() async throws {
        // A stage reviews the diff, not the criteria: one called `verifier` is due and run by `auto` like any other.
        let fx = try await RunnerFixture(
            extraConfig: "[review]\nstages = [\"verifier\"]\n[review.stage.verifier]\nskill = \"v.md\"\n")
        let id = try await fx.service.newQuickGoal(name: "header", request: brief, base: "main")
        try await fx.service.approve(id: id)
        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "one\nblue\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let review = await ReviewLoader(project: fx.project, git: fx.git).load(id: id)
        #expect(review.nextSteps.map(\.name) == ["verifier", "accept"], "the stage stays, the judge does not")

        var config = try Config.load(from: fx.project.configURL)
        config.review.auto = ["verifier"]
        let advice = await fx.service.runAutoAdvice(id: id, config: config)
        // Uncommitted work stops it before anything starts; what matters is that it got past the criteria check.
        #expect(advice.count == 1)
        #expect(advice.first.map { "\($0.outcome)".contains("uncommitted") } == true, "\(advice)")
    }

    @Test func theFirstCriterionOfAQuickGoalWithoutTheSectionAddsIt() throws {
        let head = "---\nid: g\ntitle: T\nbase: main\nbudget_usd: 1\nturn_timeout_min: 30\nquick: true\n---\n\n"
            + "## Request\n\nDo it.\n"
        for text in [head, head + "\n## Out of scope\n\n- Nothing else.\n"] {
            let file = try GoalFile.parse(text)
            #expect(file.goal.criteria.isEmpty)
            let edited = try GoalEditor.apply(.addCriterion(text: "Done.", proof: "cat a.txt"), to: file)
            #expect(edited.goal.criteria.map(\.id) == ["c1"] && edited.goal.criteria.first?.proof == "cat a.txt")
            #expect(edited.goal.request == "Do it." && edited.goal.outOfScope == file.goal.outOfScope)
            let section = "Do it.\n\n## Criteria\n\n- [c1] Done.\n  - proof: cat a.txt\n"
            #expect(edited.text.contains(section), "\(edited.text)")
            #expect(try GoalEditor.apply(.addCriterion(text: "Also.", proof: "p"), to: edited).goal.criteria.count == 2)
        }
    }

    @Test func switchToAdvanced() async throws {
        // The same request, sent to the goal agent instead (Advanced), drafts a goal with criteria that is judged as before.
        let d = try await drafting()
        let drafted = try await d.draft(request: brief)
        let id = try #require(drafted.id)
        let file = try goal(d.fx, id)
        #expect(!file.goal.quick && file.goal.criteria.map(\.id) == ["c1", "c2"])
        #expect(file.goal.unavailable("judge") == nil)

        try await d.fx.service.approve(id: id)
        _ = try await d.fx.runner(id).run(d.fx.options())
        let verdict = #"{"criteria": [{"id": "c1", "met": true, "evidence": ["e"]}, "#
            + #"{"id": "c2", "met": false, "evidence": ["f"]}], "concerns": []}"#
        let answer = try d.file("verdict.json", verdict)
        let judged = try await d.fx.service.judge(
            id: id, config: d.config, environment: d.claudeEnvironment("answer=\(answer)"))
        #expect(judged.failure == nil && judged.verdict?.criteria.map(\.met) == [true, false])
        #expect(try d.fx.kinds(id).contains("judge.ran"))
    }

    @Test func aQuickGoalIsAKeyTheApprovalBindsAndAnOtherGoalStillNeedsCriteria() throws {
        let plain = """
            ---
            id: g
            title: T
            base: main
            budget_usd: 1
            turn_timeout_min: 30
            ---

            ## Request

            Do it.
            """
        #expect(throws: GoalParseError.self) { try GoalFile.parse(plain) }
        let quickText = plain.replacingOccurrences(of: "turn_timeout_min: 30", with: "turn_timeout_min: 30\nquick: true")
        let quick = try GoalFile.parse(quickText)
        #expect(quick.goal.quick && quick.goal.criteria.isEmpty)
        let off = plain.replacingOccurrences(of: "turn_timeout_min: 30", with: "turn_timeout_min: 30\nquick: false")
        #expect(throws: GoalParseError.self) { try GoalFile.parse(off) }
        let bad = plain.replacingOccurrences(of: "turn_timeout_min: 30", with: "turn_timeout_min: 30\nquick: yes")
        #expect(throws: GoalParseError.self) { try GoalFile.parse(bad) }

        // Approving binds it: a quick goal approved, then made not quick, is no longer approved.
        let approved = try quick.approving()
        #expect(approved.goal.approval == .approved)
        let withCriterion = approved.text.replacingOccurrences(of: "quick: true\n", with: "")
            + "\n## Criteria\n\n- [c1] Done.\n  - proof: cat a.txt\n"
        #expect(try GoalFile.parse(withCriterion).goal.approval == .stale)

        // Only the setting changes here: a goal with a criterion, approved, then marked quick, is stale too.
        let withProof = plain + "\n## Criteria\n\n- [c1] Done.\n  - proof: cat a.txt\n"
        let approvedWithCriterion = try GoalFile.parse(withProof).approving()
        #expect(approvedWithCriterion.goal.approval == .approved)
        let flipped = approvedWithCriterion.text.replacingOccurrences(
            of: "turn_timeout_min: 30", with: "turn_timeout_min: 30\nquick: true")
        #expect(try GoalFile.parse(flipped).goal.approval == .stale)

        // `goal new --from` carries it, so a copy of a quick goal is one too.
        #expect(try GoalFile.copy(quick.text).settings.quick)
    }
}
