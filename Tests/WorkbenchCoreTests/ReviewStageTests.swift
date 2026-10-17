import Foundation
import Testing

@testable import WorkbenchCore

private func parse(_ section: String) throws -> Config {
    try Config.parse("\(section)\n[tools]\navailable = [\"Read\"]\n")
}

/// The problems a config is refused with, or none when it loads.
private func problems(_ section: String) -> [ConfigProblem] {
    do {
        _ = try parse(section)
        return []
    } catch let error as ConfigError { return error.problems } catch { return [] }
}

// MARK: config

@Suite struct ReviewStageConfigTests {
    @Test func noReviewConfigIsPRReviewAloneWithItsDefaults() throws {
        let review = try parse("").review
        #expect(review.stages == ["pr-review"])
        #expect(review.prReview == ReviewStageConfig(name: "pr-review"))
        #expect(review.prReview.inputs == [.diff, .goal] && review.prReview.reviewer == .codex)
        #expect(review.tables.isEmpty && review.unlistedTables.isEmpty)
    }

    @Test func aValidTwoStageConfigParses() throws {
        let config = try parse(
            """
            [review]
            stages = ["pr-review", "design"]

            [review.stage.design]
            skill = ".agents/skills/design-review/SKILL.md"
            reviewer = "claude"
            inputs = ["diff", "goal", "proof", "docs/DESIGN.md"]
            applies_to = ["Sources/Triage/**", "Resources/**"]
            max_rounds = 2
            """)
        #expect(config.review.stages == ["pr-review", "design"])
        let design = try #require(config.review.stage("design"))
        #expect(design.skill == ".agents/skills/design-review/SKILL.md" && design.prompt == nil)
        #expect(design.rubric == ".agents/skills/design-review/SKILL.md")
        #expect(design.reviewer == .claude)
        #expect(design.inputs == [.diff, .goal, .proof, .path("docs/DESIGN.md")])
        #expect(design.appliesTo == ["Sources/Triage/**", "Resources/**"])
        #expect(design.maxRounds == 2)
        #expect(config.review.prReview == ReviewStageConfig(name: "pr-review"), "pr-review keeps its built-in definition")
        #expect(config.prReview == PRReviewConfig())
    }

    @Test func aStageWithNoTableAndNoBuiltInIsRefused() {
        let found = problems("[review]\nstages = [\"pr-review\", \"design\"]\n")
        #expect(found.count == 1)
        #expect(found.first?.code == .missingKey && found.first?.line == 2)
        #expect(found.first?.message.contains("'design'") == true, "\(found)")
    }

    @Test func anUnknownInputIsRefused() {
        let found = problems("[review]\nstages = [\"x\"]\n[review.stage.x]\ninputs = [\"diff\", \"screenshots\"]\n")
        #expect(found.map(\.code) == [.invalidValue], "\(found)")
        #expect(found.first?.message.contains("'screenshots'") == true)
        #expect(found.first?.line == 4)
    }

    @Test func skillAndPromptOnOneStageAreRefused() {
        let found = problems("[review]\nstages = [\"x\"]\n[review.stage.x]\nskill = \"a/SKILL.md\"\nprompt = \"b.md\"\n")
        #expect(found.map(\.code) == [.conflict], "\(found)")
        #expect(found.first?.message.contains("'skill' and 'prompt'") == true)
    }

    @Test(arguments: [
        "[review]\nstages = []\n", "[review]\nstages = \"pr-review\"\n",
        "[review]\nstages = [\"pr-review\", \"pr-review\"]\n", "[review]\nstages = [\"Design\"]\n",
        "[review]\nstages = [1]\n", "[review]\norder = [\"pr-review\"]\n",
        "[review.stage]\nskill = \"a.md\"\n", "[review.stage.a.b]\nskill = \"a.md\"\n", "[review.stage.Big]\n",
        "[review.design]\n", "[review.stage.x]\nreviewer = \"gpt\"\n", "[review.stage.x]\nskill = \"../outside.md\"\n",
        "[review.stage.x]\nprompt = \"/etc/passwd\"\n", "[review.stage.x]\ninputs = []\n",
        "[review.stage.x]\ninputs = \"diff\"\n", "[review.stage.x]\napplies_to = [\"/abs/**\"]\n",
        "[review.stage.x]\nmax_rounds = 0\n", "[review.stage.x]\ncommand = \"x\"\n",
        "[pr_review]\nmax_rounds = 2\n[review.stage.pr-review]\nmax_rounds = 3\n",
    ])
    func aMalformedReviewTableIsRefused(section: String) {
        #expect(!problems(section).isEmpty, "expected a refusal for \(section)")
    }

    @Test func theNewTableOverridesPRReviewsSkillAndChecklist() throws {
        let config = try parse(
            """
            [review.stage.pr-review]
            skill = ".agents/skills/pr-review/SKILL.md"
            checklist = "docs/REVIEW.md"
            max_rounds = 4
            """)
        #expect(config.review.prReview.skill == ".agents/skills/pr-review/SKILL.md")
        #expect(config.review.prReview.checklist == "docs/REVIEW.md")
        #expect(config.prReview == PRReviewConfig(checklist: "docs/REVIEW.md", maxRounds: 4))
        #expect(ReviewStage.prReview(config).config == config.review.prReview)
        #expect(config.review.stages == ["pr-review"] && config.review.unlistedTables.isEmpty)
    }

    @Test func theOldTableGivesTheSameResultAsTheNewOne() throws {
        let old = try parse("[pr_review]\nchecklist = \"docs/REVIEW.md\"\nmax_rounds = 5\n")
        let new = try parse("[review.stage.pr-review]\nchecklist = \"docs/REVIEW.md\"\nmax_rounds = 5\n")
        #expect(old.review.prReview == new.review.prReview)
        #expect(old.prReview == new.prReview)
        #expect(ReviewStage.prReview(old) == ReviewStage.prReview(new))
    }

    @Test func aTableNotListedIsKeptAsUnlisted() throws {
        let review = try parse("[review.stage.design]\nprompt = \"docs/REVIEW-DESIGN.md\"\n").review
        #expect(review.stages == ["pr-review"])
        #expect(review.unlistedTables == ["design"])
        #expect(review.stage("design")?.rubric == "docs/REVIEW-DESIGN.md")
    }

    @Test func onlyWhatTheRunnerDoesNotUseYetIsWarnedAbout() throws {
        #expect(ReviewStage.prReview(try parse("")).notYetUsedWarning == nil)
        #expect(ReviewStage.prReview(try parse("[review.stage.pr-review]\nchecklist = \"a.md\"\n")).notYetUsedWarning == nil)
        #expect(ReviewStage.prReview(try parse("[review.stage.pr-review]\nskill = \"a/SKILL.md\"\n")).notYetUsedWarning == nil)
        let inputs = ReviewStage.prReview(try parse("[review.stage.pr-review]\ninputs = [\"diff\"]\n"))
        #expect(inputs.notYetUsedWarning?.contains("sets inputs,") == true, "\(inputs.notYetUsedWarning ?? "")")
    }
}

// MARK: the rubric

@Suite struct ReviewStageRubricTests {
    private func stage(_ section: String) throws -> ReviewStage { ReviewStage.prReview(try parse(section)) }

    @Test func aSkillsRubricSectionIsTheRubric() throws {
        let skill = try stage("[review.stage.pr-review]\nskill = \"a/SKILL.md\"\n")
        let text =
            "# Skill\n\n## Steps\n\nRun swift build.\n\n## Rubric\n\n- flag every force unwrap\n\n"
            + "## Posting\n\ngh pr comment\n"
        #expect(skill.rubric(from: text) == "- flag every force unwrap")
    }

    @Test func aHeadingInsideAFencedExampleDoesNotEndTheRubricSection() throws {
        let skill = try stage("[review.stage.pr-review]\nskill = \"a/SKILL.md\"\n")
        let text = """
            # Skill

            ## Rubric

            Report like this:

            ```markdown
            ## Example
            - a finding
            ```

            - check the locks

            ## Posting

            gh pr comment
            """
        let rubric = try #require(skill.rubric(from: text))
        #expect(rubric.contains("## Example") && rubric.contains("- check the locks"), "\(rubric)")
        #expect(!rubric.contains("gh pr comment"))
    }

    @Test func aRubricHeadingInsideAFencedExampleIsNotTheSection() throws {
        let skill = try stage("[review.stage.pr-review]\nskill = \"a/SKILL.md\"\n")
        let text = """
            # Skill

            Write the section like:

            ~~~
            ## Rubric
            - not this one
            ~~~

            ## Rubric

            - the real check
            """
        #expect(skill.rubric(from: text) == "- the real check")
    }

    @Test func aSkillWithoutARubricSectionIsUsedWholeUnderTheIgnoreStepsHeader() throws {
        let skill = try stage("[review.stage.pr-review]\nskill = \"a/SKILL.md\"\n")
        let rubric = try #require(skill.rubric(from: "# Skill\n\nRun swift build, then check the locks.\n"))
        #expect(rubric.hasPrefix(ReviewStage.skillHeader))
        #expect(rubric.contains("Run swift build, then check the locks."))
    }

    @Test func aPromptFileIsUsedWholeAndAnEmptyRubricIsNone() throws {
        let promptStage = try stage("[review.stage.pr-review]\nprompt = \"docs/REVIEW-PR.md\"\n")
        let file = "## Rubric\nonly this?\n## Other\nand this\n"
        #expect(promptStage.rubric(from: file) == file)
        #expect(promptStage.rubric(from: " \n\n") == nil)
        let skill = try stage("[review.stage.pr-review]\nskill = \"a/SKILL.md\"\n")
        #expect(skill.rubric(from: "## Rubric\n\n## Next\n") == nil)
    }
}

// MARK: the runner

@Suite struct ReviewStageRunnerTests {
    @Test func theNewTablesChecklistReachesTheBriefAsTheOldOneDoes() async throws {
        for table in ["[pr_review]", "[review.stage.pr-review]"] {
            let r = try await reviewedPR(extraConfig: "\(table)\nchecklist = \"docs/REVIEW.md\"\n")
            let worktree = r.fx.project.worktreesDirectory.appendingPathComponent(r.id)
            try FileManager.default.createDirectory(
                at: worktree.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try "- never block\n".write(
                to: worktree.appendingPathComponent("docs/REVIEW.md"), atomically: true, encoding: .utf8)
            _ = try await r.fx.git.run(["add", "-A"], in: worktree)
            _ = try await r.fx.git.run(["commit", "-q", "-m", "docs: checklist"], in: worktree)
            _ = try await r.fx.git.run(["push", "-q", "origin", "HEAD:refs/heads/workbench/\(r.id)"], in: worktree)

            let result = try await r.round()
            #expect(result.verdict == .clean && result.warnings.isEmpty, "\(table)")
            #expect(r.codex.read("brief_1")?.contains("- never block") == true, "\(table)")
            #expect(r.started.count == 1 && r.finished.count == 1, "\(table): still pr_review.* events")
        }
    }

    @Test func aConfiguredSkillsRubricReachesTheBriefInPlaceOfTheBuiltInReport() async throws {
        let r = try await reviewedPR(extraConfig: "[review.stage.pr-review]\nskill = \".agents/skills/pr-review/SKILL.md\"\n")
        try await commit(
            "# PR review\n\n## Steps\n\nPost the findings with gh.\n\n## Rubric\n\n- every lock is named zebra-7731\n",
            at: ".agents/skills/pr-review/SKILL.md", in: r)
        let result = try await r.round()
        #expect(result.verdict == .clean && result.warnings.isEmpty, "\(result.warnings)")
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("## Rubric (.agents/skills/pr-review/SKILL.md)"))
        #expect(brief.contains("- every lock is named zebra-7731"))
        #expect(!brief.contains("Post the findings with gh."), "only the rubric section")
        #expect(!brief.contains("## Report"), "the rubric replaces the built-in report instructions")
        #expect(brief.contains("# Review pull request #") && brief.contains(PRReview.cleanLine))
        #expect(r.started.count == 1 && r.finished.count == 1)
    }

    @Test func rubricTextWithShellMetacharactersReachesTheReviewerOnlyThroughTheBriefFile() async throws {
        let r = try await reviewedPR(extraConfig: "[review.stage.pr-review]\nprompt = \"docs/REVIEW-PR.md\"\n")
        let hostile = "- never run $(touch pwned-7731) or `touch pwned-7731`; \"quoted\" 'single' ; rm -rf x"
        try await commit(hostile + "\n", at: "docs/REVIEW-PR.md", in: r)
        let result = try await r.round()
        #expect(result.verdict == .clean, "\(result.failure ?? "")")
        #expect(r.codex.read("brief_1")?.contains(hostile) == true, "the text arrives unchanged in the file")
        #expect(r.codex.read("calls")?.contains("pwned-7731") == false, "and never on the command line")
        #expect(r.codex.read("cwds")?.contains("pwned") == false)
    }

    @Test func anEmptyRubricFileFailsTheRoundBeforeCodexRuns() async throws {
        let r = try await reviewedPR(extraConfig: "[review.stage.pr-review]\nprompt = \"docs/REVIEW-PR.md\"\n")
        try await commit("  \n\n", at: "docs/REVIEW-PR.md", in: r)
        let result = try await r.round()
        #expect(result.verdict == nil)
        #expect(result.failure?.contains("docs/REVIEW-PR.md") == true, "\(result.failure ?? "")")
        #expect(r.codex.read("brief_1") == nil)
        #expect(r.started.count == 1 && r.finished.count == 1, "the round is still recorded")
    }

    @Test func aConfiguredSkillThatIsNotInThePullRequestFailsTheRound() async throws {
        let r = try await reviewedPR(extraConfig: "[review.stage.pr-review]\nskill = \".agents/skills/pr-review/SKILL.md\"\n")
        let result = try await r.round()
        #expect(result.verdict == nil)
        #expect(result.failure?.contains(".agents/skills/pr-review/SKILL.md") == true, "\(result.failure ?? "")")
        #expect(r.codex.read("brief_1") == nil, "Codex is not run without the rubric")
    }

    private func commit(_ text: String, at path: String, in r: ReviewedPR) async throws {
        let worktree = r.fx.project.worktreesDirectory.appendingPathComponent(r.id)
        let url = worktree.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        _ = try await r.fx.git.run(["add", "-A"], in: worktree)
        _ = try await r.fx.git.run(["commit", "-q", "-m", "docs: rubric"], in: worktree)
        _ = try await r.fx.git.run(["push", "-q", "origin", "HEAD:refs/heads/workbench/\(r.id)"], in: worktree)
    }
}

// MARK: doctor

@Suite struct ReviewStageDoctorTests {
    private func doctor(_ extra: String, files: [String] = []) async throws -> DoctorReport {
        let fx = try await RunnerFixture(extraConfig: extra)
        for file in files {
            let url = fx.repo.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# rubric\n".write(to: url, atomically: true, encoding: .utf8)
        }
        var options = Doctor.Options()
        options.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        options.screenRecordingGranted = { true }
        return try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options)
    }

    @Test func theDefaultConfigHasNoReviewWarnings() async throws {
        let report = try await doctor("")
        #expect(report.reviewWarnings.isEmpty)
        #expect(report.passed)
    }

    @Test func aListWithoutPRReviewWarnsAndDoesNotFail() async throws {
        let report = try await doctor(
            "[review]\nstages = [\"design\"]\n[review.stage.design]\nprompt = \"docs/REVIEW-DESIGN.md\"\n",
            files: ["docs/REVIEW-DESIGN.md"])
        #expect(report.reviewWarnings.count == 1, "\(report.reviewWarnings)")
        #expect(report.reviewWarnings.first?.contains("does not list pr-review") == true)
        #expect(report.passed)
    }

    @Test func aMissingRubricFileWarnsAndDoesNotFail() async throws {
        let report = try await doctor(
            "[review]\nstages = [\"pr-review\", \"design\"]\n"
                + "[review.stage.design]\nskill = \".agents/skills/design-review/SKILL.md\"\n")
        #expect(report.reviewWarnings == [
            "the design stage's skill .agents/skills/design-review/SKILL.md is not a file in this checkout",
        ])
        #expect(report.passed)

        let present = try await doctor(
            "[review]\nstages = [\"pr-review\", \"design\"]\n"
                + "[review.stage.design]\nskill = \".agents/skills/design-review/SKILL.md\"\n",
            files: [".agents/skills/design-review/SKILL.md"])
        #expect(present.reviewWarnings.isEmpty)
    }

    @Test func aTableNotListedInStagesWarnsAndDoesNotFail() async throws {
        let report = try await doctor(
            "[review.stage.design]\nprompt = \"docs/REVIEW-DESIGN.md\"\n", files: ["docs/REVIEW-DESIGN.md"])
        #expect(report.reviewWarnings == ["[review.stage.design] is not listed in review.stages, so it is ignored"])
        #expect(report.passed)
    }
}
