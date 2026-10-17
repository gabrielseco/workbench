import Foundation
import Testing

@testable import WorkbenchCore

/// `[review]` with pr-review and one more stage, `design`, whose table is `designTable`.
private func stagesConfig(_ designTable: String = "", extraStages: String = "", before: String = "") -> String {
    "\(before)\n[review]\nstages = [\"pr-review\", \"design\"\(extraStages)]\n[review.stage.design]\n\(designTable)\n"
}

private func runStage(
    _ name: String, _ r: ReviewedPR, again: Bool = false, config: Config? = nil
) async throws -> PRReviewResult {
    try await r.fx.service.reviewStage(
        named: name, id: r.id, config: config ?? r.config, again: again, codexPath: r.codex.path,
        environment: r.codex.environment(), timeout: 30, capacityBackoff: { _ in 0 })
}

private func stageEvents(_ r: ReviewedPR, _ kind: EventKind, stage: String = "design") -> [Event] {
    ((try? r.fx.events(r.id)) ?? []).filter { $0.kind == kind && $0.data["stage"]?.stringValue == stage }
}

/// A verify script that writes `files` (name to content) into the proof directory, `/` making folders.
private func verifyConfig(_ files: [String: String]) throws -> String {
    let writes = files.map { name, text in
        "mkdir -p \"$(dirname \"$WORKBENCH_PROOF_DIR/\(name)\")\"; printf '\(text)' > \"$WORKBENCH_PROOF_DIR/\(name)\""
    }
    let script = try CheckScript().write(writes.joined(separator: "\n"), name: "verify.sh")
    return "verify_command = \"\(script)\""
}

// MARK: running a stage

@Suite struct ReviewStageCommandTests {
    @Test func aConfiguredStageRunsAndIsRecordedAsReviewStageEventsOnce() async throws {
        let r = try await reviewedPR(extraConfig: stagesConfig("max_rounds = 2"), answer: "Looks fine.\nVERDICT: CLEAN\n")
        let result = try await runStage("design", r)
        #expect(result.verdict == .clean && result.round == 1 && result.maxRounds == 2, "\(result)")
        #expect(result.findingsPath == "design/round-1.findings.md")
        let started = stageEvents(r, .reviewStageStarted)
        let finished = stageEvents(r, .reviewStageFinished)
        #expect(started.count == 1 && finished.count == 1)
        #expect(started.first?.data["round"]?.intValue == 1 && started.first?.data["pr"]?.intValue == 12)
        #expect(started.first?.data["head_sha"]?.stringValue == r.head)
        let end = try #require(finished.first)
        #expect(end.data["ok"] == true && end.data["verdict"]?.stringValue == "clean")
        #expect(end.data["findings_path"]?.stringValue == "design/round-1.findings.md")
        let stored = r.fx.project.threadDirectory(r.id).appendingPathComponent("design/round-1.findings.md")
        #expect(try String(contentsOf: stored, encoding: .utf8).contains("Looks fine."))
        #expect(r.started.isEmpty && r.finished.isEmpty, "no pr_review.* events for another stage")
        #expect(r.codex.read("brief_1")?.contains("# Review pull request #12") == true)
        try await r.expectNoLeftovers()
    }

    @Test func aNameNotInReviewStagesIsRefusedAndNothingRuns() async throws {
        let r = try await reviewedPR(
            extraConfig: stagesConfig() + "[review.stage.unlisted]\nmax_rounds = 1\n")
        for name in ["nope", "unlisted"] {
            await #expect(throws: PRReviewRefusal.unknownStage(name, listed: ["pr-review", "design"])) {
                _ = try await runStage(name, r)
            }
        }
        #expect(r.codex.runs == 0)
        #expect(((try? r.fx.events(r.id)) ?? []).allSatisfy { $0.kind != .reviewStageStarted })
    }

    @Test func pullRequestReviewStillWritesItsOwnEvents() async throws {
        let r = try await reviewedPR(extraConfig: stagesConfig())
        let result = try await runStage("pr-review", r)
        #expect(result.verdict == .clean && result.findingsPath == "pr-review/round-1.findings.md")
        #expect(r.started.count == 1 && r.finished.count == 1)
        #expect(r.started.first?.data["stage"] == nil, "pr_review.* events are unchanged")
        #expect(stageEvents(r, .reviewStageStarted, stage: "pr-review").isEmpty)
    }
}

// MARK: round caps

@Suite struct ReviewStageCapTests {
    @Test func eachStageCountsItsOwnRoundsAndAgainDoesNotLiftTheCap() async throws {
        let r = try await reviewedPR(
            extraConfig: stagesConfig("max_rounds = 1", before: "[review.stage.pr-review]\nmax_rounds = 2\n"))
        let first = try await runStage("design", r)
        #expect(first.round == 1 && first.maxRounds == 1)
        await #expect(throws: PRReviewRefusal.stageCapReached(stage: "design", pr: 12, rounds: 1, max: 1)) {
            _ = try await runStage("design", r, again: true)
        }

        let review = try await runStage("pr-review", r)
        #expect(review.round == 1 && review.maxRounds == 2, "pr-review does not count design's round")
        let second = try await runStage("pr-review", r, again: true)
        #expect(second.round == 2)
        await #expect(throws: PRReviewRefusal.capReached(pr: 12, rounds: 2, max: 2)) {
            _ = try await runStage("pr-review", r, again: true)
        }
        #expect(stageEvents(r, .reviewStageStarted).count == 1 && r.started.count == 2)
        #expect(r.codex.runs == 3)
    }

    @Test func theCapMessageNamesTheStagesTable() {
        let text = "\(PRReviewRefusal.stageCapReached(stage: "design", pr: 12, rounds: 2, max: 2))"
        #expect(text.contains("[review.stage.design]") && text.contains("2 times"), "\(text)")
    }
}

// MARK: the reviewer

@Suite struct ReviewStageReviewerTests {
    private func load(_ table: String) throws -> Config {
        try Config.parse(
            "[review]\nstages = [\"pr-review\", \"design\"]\n[review.stage.design]\n\(table)\n[tools]\navailable = [\"Read\"]\n")
    }

    @Test func claudeIsRefusedAtConfigLoad() {
        do {
            _ = try load("reviewer = \"claude\"")
            Issue.record("a claude reviewer loaded")
        } catch let error as ConfigError {
            #expect(error.problems.count == 1)
            #expect(error.problems.first?.message.contains("review stages run on Codex") == true, "\(error.problems)")
            #expect(error.problems.first?.line == 4)
        } catch { Issue.record("\(error)") }
    }

    @Test func codexOrNoReviewerLoadsAndIsNotWarnedAbout() throws {
        for table in ["reviewer = \"codex\"", ""] {
            let config = try load(table)
            let stage = try #require(ReviewStage.named("design", config: config))
            #expect(stage.config.reviewer == .codex)
            #expect(stage.notYetUsedWarning == nil, "\(table)")
        }
    }
}

// MARK: proof

@Suite struct ReviewStageProofTests {
    @Test func theVerifyStepsTopLevelPNGsAreInTheBriefAndAttachedWithDashI() async throws {
        let verify = try verifyConfig(["home.png": "pixels", "dark.png": "night", "notes.txt": "x", "sub/deep.png": "d"])
        let r = try await reviewedPR(extraConfig: stagesConfig("inputs = [\"diff\", \"goal\", \"proof\"]", before: verify))
        let result = try await runStage("design", r)
        #expect(result.verdict == .clean, "\(result.failure ?? "")")
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        let proof = r.fx.project.proofDirectory(r.id, turn: 1)
        let home = proof.appendingPathComponent("home.png").path
        let dark = proof.appendingPathComponent("dark.png").path
        let brief = try #require(r.codex.read("brief_1"))
        #expect(brief.contains("## Proof") && brief.contains("- \(home)") && brief.contains("- \(dark)"), "\(brief)")
        #expect(!brief.contains("notes.txt") && !brief.contains("deep.png"))
        let call = try #require(r.codex.calls.first)
        #expect(call.contains("-i \(home)") && call.contains("-i \(dark)"), "\(call)")
        #expect(!call.contains("deep.png") && !call.contains("notes.txt"))
        let argv = stageEvents(r, .reviewStageStarted).first?.data["argv"]
        #expect("\(String(describing: argv))".contains("home.png"), "the recorded argv shows the images")
    }

    @Test func noPNGLeftFailsTheRoundAndCodexDoesNotRun() async throws {
        let verify = try verifyConfig(["notes.txt": "x"])
        let r = try await reviewedPR(extraConfig: stagesConfig("inputs = [\"proof\", \"diff\", \"goal\"]", before: verify))
        let result = try await runStage("design", r)
        #expect(result.verdict == nil)
        #expect(result.failure?.contains("left no PNG") == true, "\(result.failure ?? "")")
        #expect(r.codex.runs == 0)
        let end = try #require(stageEvents(r, .reviewStageFinished).first)
        #expect(end.data["ok"] == false && end.data["verdict"] == .null)
    }

    @Test func noVerifyStepFailsTheRound() async throws {
        let r = try await reviewedPR(extraConfig: stagesConfig("inputs = [\"diff\", \"goal\", \"proof\"]"))
        let result = try await runStage("design", r)
        #expect(result.verdict == nil && result.failure?.contains("no verify step") == true, "\(result.failure ?? "")")
        #expect(r.codex.runs == 0)
    }

    @Test func aVerifyStepFromBeforeTheLatestTurnFailsTheRound() async throws {
        let verify = try verifyConfig(["home.png": "pixels"])
        let r = try await reviewedPR(extraConfig: stagesConfig("inputs = [\"diff\", \"goal\", \"proof\"]", before: verify))
        let log = try EventLogWriter.open(at: r.fx.project.eventsURL(r.id))
        _ = try await log.append(.turnStarted, turn: 2, data: ["session_id": "s", "resume": true])
        _ = try await log.append(.turnEnded, turn: 2, data: ["result": "success"])
        await log.close()

        let result = try await runStage("design", r)
        #expect(result.verdict == nil)
        #expect(result.failure?.contains("before the latest turn 2") == true, "\(result.failure ?? "")")
        #expect(r.codex.runs == 0)
    }
}

// MARK: applies_to

@Suite struct ReviewStageAppliesToTests {
    @Test func aStageMatchingNoChangedFileIsSkippedAndRunsNoReviewer() async throws {
        let r = try await reviewedPR(extraConfig: stagesConfig("applies_to = [\"Sources/**\", \"*.swift\"]"))
        let result = try await runStage("design", r)
        #expect(result.skipped?.contains("Sources/**, *.swift") == true, "\(result)")
        #expect(result.verdict == nil && result.failure == nil)
        #expect(r.codex.runs == 0)
        #expect(stageEvents(r, .reviewStageStarted).isEmpty, "a skip spends no round")
        let end = try #require(stageEvents(r, .reviewStageFinished).first)
        #expect(end.data["verdict"]?.stringValue == "skipped" && end.data["ok"] == false)
        #expect(end.data["reason"]?.stringValue?.contains("Sources/**") == true)
        #expect(end.data["round"]?.intValue == 1 && end.data["head_sha"]?.stringValue == r.head)
        let record = try #require(
            r.fx.service.latestReviewStages(id: r.id, review: r.config.review).first { $0.name == "design" }?.record)
        #expect(record.skipped && record.verdict == nil && !record.ok, "never clean")
    }

    @Test(arguments: ["**/a.txt", "*", "*.txt", "**"])
    func aStageMatchingAChangedFileRuns(glob: String) async throws {
        let r = try await reviewedPR(extraConfig: stagesConfig("applies_to = [\"Sources/**\", \"\(glob)\"]"))
        let result = try await runStage("design", r)
        #expect(result.skipped == nil && result.verdict == .clean, "\(glob): \(result)")
        #expect(r.codex.runs == 1)
        #expect(stageEvents(r, .reviewStageStarted).count == 1)
    }

    @Test func globs() {
        let yes: [(String, String)] = [
            ("**", "a.txt"), ("**", "a/b/c.swift"), ("**/a.txt", "a.txt"), ("**/a.txt", "x/y/a.txt"),
            ("Sources/**", "Sources/a/b.swift"), ("Sources/**/*.swift", "Sources/b.swift"), ("*", "a.txt"),
            ("*.md", "README.md"), ("a?c", "abc"), ("Resources/**", "Resources/x.png"),
        ]
        let no: [(String, String)] = [
            ("*", "a/b.txt"), ("*.md", "docs/README.md"), ("Sources/**", "Tests/a.swift"), ("Sources/*", "Sources/a/b"),
            ("a?c", "ac"), ("**/a.txt", "b.txt"),
        ]
        for (pattern, path) in yes { #expect(ReviewStage.glob(pattern, matches: path), "\(pattern) ~ \(path)") }
        for (pattern, path) in no { #expect(!ReviewStage.glob(pattern, matches: path), "\(pattern) !~ \(path)") }
    }

    @Test func pullRequestReviewIgnoresAppliesToAndSaysSo() async throws {
        let r = try await reviewedPR(extraConfig: "[review.stage.pr-review]\napplies_to = [\"Sources/**\"]\n")
        let result = try await runStage("pr-review", r)
        #expect(result.skipped == nil && result.verdict == .clean)
        #expect(result.warnings.first?.contains("applies_to") == true, "\(result.warnings)")
    }
}

// MARK: the command and --json

private struct CLIRun {
    var code: Int32?
    var stdout: String
    var stderr: String
}

private func runCLI(_ arguments: [String], _ r: ReviewedPR) async throws -> CLIRun {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: [
            "PATH": "\(r.codex.dir.path):/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
            "CODEX_FAKE_DIR": r.codex.dir.path,
        ],
        workingDirectory: r.fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    let process = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in process.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return CLIRun(code: code, stdout: lines.joined(separator: "\n"), stderr: exit?.stderrTail ?? "")
}

@Suite struct ReviewStageCLITests {
    @Test func reviewStageRunsTheStageAndAnUnknownNameExitsSix() async throws {
        let r = try await reviewedPR(extraConfig: stagesConfig(), answer: "1. Contrast.\nVERDICT: FIX\n")
        let run = try await runCLI(["review-stage", "design"], r)
        #expect(run.code == 15, "\(run)")
        #expect(run.stdout.contains("1. Contrast.") && run.stdout.contains("design round 1 of 3, pull request #12"))
        let unknown = try await runCLI(["review-stage", "nope"], r)
        #expect(unknown.code == 6, "\(unknown)")
        #expect(unknown.stderr.contains("no review stage 'nope'"), "\(unknown.stderr)")
        #expect(try await runCLI(["review-stage"], r).code == 2)
        #expect(r.codex.runs == 1)
    }

    @Test func aSkipPrintsSoAndExitsZero() async throws {
        let r = try await reviewedPR(extraConfig: stagesConfig("applies_to = [\"Sources/**\"]"))
        let run = try await runCLI(["review-stage", "design", r.id], r)
        #expect(run.code == 0, "\(run)")
        #expect(run.stdout.contains("design: skipped, the diff touches no matching path"), "\(run.stdout)")
        #expect(r.codex.runs == 0)
    }

    @Test func reviewJSONCarriesEachStagesLatestRoundAndKeepsPRReview() async throws {
        let r = try await reviewedPR(
            extraConfig: stagesConfig(extraStages: ", \"docs\"") + "[review.stage.docs]\napplies_to = [\"docs/**\"]\n")
        #expect(try await runCLI(["review-stage", "design"], r).code == 0)
        #expect(try await runCLI(["review-stage", "docs"], r).code == 0)
        let run = try await runCLI(["review", "--json"], r)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        #expect(object["pr_review"] is NSNull, "the old key is unchanged: pr-review has not run")
        let stages = try #require(object["review_stages"] as? [[String: Any]])
        #expect(stages.map { $0["name"] as? String } == ["pr-review", "design", "docs"])
        for stage in stages { #expect(Set(stage.keys) == ["name", "round", "verdict", "stale", "skipped", "findings_path"]) }
        #expect(stages[0]["round"] is NSNull && stages[0]["verdict"] is NSNull && stages[0]["skipped"] as? Bool == false)
        #expect(stages[1]["round"] as? Int == 1 && stages[1]["verdict"] as? String == "clean")
        #expect(stages[1]["stale"] as? Bool == false && stages[1]["skipped"] as? Bool == false)
        #expect(stages[1]["findings_path"] as? String == "design/round-1.findings.md")
        #expect(stages[2]["verdict"] as? String == "skipped" && stages[2]["skipped"] as? Bool == true)
        #expect(stages[2]["findings_path"] is NSNull)
    }
}

// MARK: doctor

@Suite struct ReviewStageProofDoctorTests {
    @Test func aProofStageWithoutAVerifyCommandWarnsAndDoesNotFail() async throws {
        let fx = try await RunnerFixture(extraConfig: stagesConfig("inputs = [\"diff\", \"goal\", \"proof\"]"))
        var options = Doctor.Options()
        options.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        options.screenRecordingGranted = { true }
        let report = try await Doctor(project: fx.project, git: fx.git).run(base: "main", options: options)
        #expect(report.reviewWarnings == [
            "the design stage reads proof, and there is no verify_command to leave any: its rounds will fail",
        ])
        #expect(report.passed)
    }

    @Test func aProofStageWithAVerifyCommandHasNoWarning() throws {
        let config = try Config.parse(
            stagesConfig("inputs = [\"diff\", \"goal\", \"proof\"]") + "[tools]\navailable = [\"Read\"]\n")
        let root = FileManager.default.temporaryDirectory
        #expect(Doctor.reviewWarnings(config.review, root: root, hasVerifyCommand: true).isEmpty)
        #expect(Doctor.reviewWarnings(config.review, root: root, hasVerifyCommand: false).count == 1)
    }
}
