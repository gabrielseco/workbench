import Foundation
import Testing

@testable import WorkbenchCore

private let secret = "/Users/someone/work/project/file.ex"

struct SeriesReportFindingsTests {
    @Test func theSeverityAndTitleOfEachFindingAreRead() {
        let text = """
            - **[P1] Concurrent retries can store a second file.** If two requests pass the lookup, each writes a key.

            - **[P2] The body cap does not apply to other content types.** A body over 6 MB is a 422.
            * **P3 — A note about naming.** Rename it.

            Criteria assessment:
            - **c1:** holds
            VERDICT: FIX
            """
        let found = SeriesReporter.findings(in: text)
        #expect(
            found == [
                SeriesReportFinding(severity: "P1", title: "Concurrent retries can store a second file"),
                SeriesReportFinding(severity: "P2", title: "The body cap does not apply to other content types"),
                SeriesReportFinding(severity: "P3", title: "A note about naming"),
            ])
        #expect(SeriesReporter.findings(in: nil).isEmpty)
        #expect(SeriesReporter.findings(in: "No findings.\nVERDICT: CLEAN").isEmpty)
    }
}

struct SeriesReportMarkdownTests {
    private func step(_ number: Int, state: SeriesStepState, rounds: [SeriesReportRound] = []) -> SeriesReportStep {
        SeriesReportStep(
            number: number, project: "/p", goalTitle: "Goal | \(number)", state: state, thread: "g-1-s-\(number)",
            pullRequest: "https://example.test/pull/\(number)", additions: 10, deletions: 2, files: ["a.ex", "b.ex"], turns: 2,
            costUSD: 1.5, costUnknown: false, check: "passed after turn 1", verifier: nil,
            criteria: [
                SeriesReportCriterion(id: "c1", text: "It works.", met: true),
                SeriesReportCriterion(id: "c2", text: "It is tested.", met: false),
            ],
            judgeConcerns: ["A concern."], judgeTurn: 1, built: "Built it in \(secret)", rounds: rounds, manual: [])
    }

    @Test func theSummaryTableTheMergeOrderAndEachStepAreWritten() {
        let fix = SeriesReportFix(
            thread: "g-1-s-1-review-1", costUSD: 0.5, costUnknown: false, turns: 1, commits: ["fix: the thing"],
            said: "Fixed P1.\nLeft P2.")
        let round = SeriesReportRound(
            round: 1, verdict: "fix", findings: [SeriesReportFinding(severity: "P1", title: "A bug")],
            findingsFile: ".workbench/threads/g-1-s-1/pr-review/round-1.findings.md", fix: fix)
        let report = SeriesReport(
            name: "s", generated: "2026-11-21T10:00:00Z", budgetUSD: 30,
            steps: [
                step(1, state: .clean(thread: "g-1-s-1", pullRequest: nil), rounds: [round]),
                step(2, state: .stopped(thread: "g-1-s-2", reason: "checks failed: test")),
            ])
        let text = report.markdown
        #expect(text.contains("# Series s: report"))
        #expect(text.contains("1 of 2 steps clean"))
        #expect(text.contains("of the $30.00 series budget"))
        #expect(text.contains("| 1 | Goal / 1 | clean |"))
        #expect(text.contains("STOPPED (checks failed: test)"))
        #expect(text.contains("FIX"))
        #expect(text.contains("1. https://example.test/pull/1") && text.contains("series rebase s"))
        #expect(text.contains("judge after turn 1, before the review fixes: 1 of 2 criteria met"))
        #expect(text.contains("- ✔ c1: It works.") && text.contains("- ✘ c2: It is tested."))
        #expect(text.contains("  - P1 A bug"))
        #expect(text.contains("Answered by `g-1-s-1-review-1` ($0.50)") && text.contains("commit: fix: the thing"))
        #expect(text.contains("> Fixed P1."))
        #expect(text.contains("Whole answer: `.workbench/threads/g-1-s-1/pr-review/round-1.findings.md`"))
        #expect(text.contains("+10 −2 in 2 files"))
    }

    @Test func textFromAnAgentIsScrubbedOfMachinePathsAndCut() {
        var report = SeriesReport(name: "s", generated: "t", budgetUSD: nil, steps: [step(1, state: .pending)])
        report.steps[0].built = String(repeating: "word ", count: 600) + secret
        let text = report.markdown
        #expect(!text.contains(secret))
        #expect(text.contains("…"))
        #expect(!text.contains("series budget"))
    }

    @Test func credentialsOfTheKnownFormsAreHiddenWhereverAgentTextAppears() {
        let leaks = [
            "ghp_abcdefghijklmnop1234", "https://user:hunter2@example.test/repo", "Authorization: Bearer abc.def.ghi",
            "API_TOKEN=sup3rs3cret", "client_secret: topsecretvalue", "?access_token=zzz999",
        ]
        let words = ["hunter2", "sup3rs3cret", "topsecretvalue", "zzz999", "abcdefghijklmnop1234", "abc.def.ghi"]
        var one = step(1, state: .clean(thread: "t", pullRequest: nil))
        one.built = leaks.joined(separator: "\n")
        one.rounds = [
            SeriesReportRound(
                round: 1, verdict: "fix", findings: [SeriesReportFinding(severity: "P1", title: leaks[3])], findingsFile: nil,
                fix: SeriesReportFix(thread: "f", costUSD: 0, costUnknown: false, turns: 1, commits: [leaks[0]], said: leaks[4]))
        ]
        let text = SeriesReport(name: "s", generated: "t", budgetUSD: nil, steps: [one]).markdown
        for word in words { #expect(!text.contains(word), "\(word) leaked") }
        #expect(text.contains("<redacted>"))
    }

    @Test func aPathInsideTheCutIsScrubbedToo() {
        var one = step(1, state: .pending)
        one.built = "Edited \(secret) and ran the tests."
        let text = SeriesReport(name: "s", generated: "t", budgetUSD: nil, steps: [one]).markdown
        #expect(!text.contains(secret) && text.contains("<path>"))
    }

    @Test func aCutAccountSaysWhereTheWholeOneIs() {
        var one = step(1, state: .pending)
        one.built = String(repeating: "word ", count: 600)
        one.rounds = [
            SeriesReportRound(
                round: 1, verdict: "fix", findings: [], findingsFile: nil,
                fix: SeriesReportFix(
                    thread: "g-1-fix", costUSD: 0, costUnknown: false, turns: 1, commits: [],
                    said: String(repeating: "x ", count: 800)))
        ]
        let text = SeriesReport(name: "s", generated: "t", budgetUSD: nil, steps: [one]).markdown
        #expect(text.contains("the whole account: `workbench log g-1-s-1`"))
        #expect(text.contains("the whole account: `workbench log g-1-fix`"))
    }

    @Test func aCostThatIsAtLeastTheFigureSaysSo() {
        var one = step(1, state: .pending)
        one.costUnknown = true
        let report = SeriesReport(name: "s", generated: "t", budgetUSD: nil, steps: [one])
        #expect(report.totalCostUnknown)
        #expect(report.markdown.contains("$1.50+ (a turn reported no cost)"))
    }

    @Test func aStepNotStartedIsSaidSoAndHasNoPullRequestInTheMergeOrder() {
        let notStarted = SeriesReportStep(
            number: 1, project: "/p", goalTitle: "Later", state: .pending, thread: nil, pullRequest: nil, additions: nil,
            deletions: nil, files: [], turns: 0, costUSD: 0, costUnknown: false, check: nil, verifier: nil, criteria: [],
            judgeConcerns: [],
            judgeTurn: nil, built: nil, rounds: [], manual: [])
        let text = SeriesReport(name: "s", generated: "t", budgetUSD: nil, steps: [notStarted]).markdown
        #expect(text.contains("Not started."))
        #expect(!text.contains("Merge in this order"))
    }

    @Test func aRoundNoLoopFollowUpAnsweredAndWorkDoneByHandAreBothShown() {
        var one = step(1, state: .clean(thread: "t", pullRequest: nil))
        one.rounds = [SeriesReportRound(round: 3, verdict: "fix", findings: [], findingsFile: nil, fix: nil)]
        one.manual = [
            SeriesReportFix(
                thread: "g-1-rework", costUSD: 0.54, costUnknown: false, turns: 1, commits: ["fix: rework"],
                said: "Removed the job.")
        ]
        let text = SeriesReport(name: "s", generated: "t", budgetUSD: nil, steps: [one]).markdown
        #expect(text.contains("No review-loop follow-up answered this round"))
        #expect(text.contains("Also pushed to this branch outside the review rounds") && text.contains("`g-1-rework` ($0.54)"))
        #expect(text.contains("(the findings are in the file below)"))
    }
}

private func line(_ seq: Int, _ turn: Int, _ kind: String, _ data: String = "{}") -> String {
    let ts = "2026-11-21T10:00:\(String(format: "%02d", seq)).000Z"
    return #"{"v":1,"seq":\#(seq),"ts":"\#(ts)","turn":\#(turn),"kind":"\#(kind)","data":\#(data)}"#
}

private func goalFile(_ id: String, title: String, pushTo: String? = nil, request: String = "Do it.") -> String {
    """
    ---
    id: \(id)
    title: \(title)
    status: draft
    base: \(pushTo.map { "origin/\($0)" } ?? "main")\(pushTo.map { "\npush_to: \($0)" } ?? "")
    budget_usd: 1.00
    turn_timeout_min: 10
    ---

    ## Request

    \(request)

    ## Criteria

    - [c1] It works.
      - proof: a test
    - [c2] It is tested.
      - proof: a test

    ## Out of scope

    - Nothing.
    """
}

@Suite(.processGate) struct SeriesReporterTests {
    /// A one-step series whose thread has a judge reading, a pull request, one review round that said FIX, a follow-up that
    /// answered it and a clean second round, plus a thread someone made on the same branch by hand.
    private func fixture() async throws -> (SeriesReporter, RunnerFixture) {
        let fx = try await RunnerFixture(extraConfig: #"check_command = "true""#)
        let project = fx.project
        let root = "g-2026-11-21-s-1"
        let follow = "g-2026-11-21-s-1-review-1"
        let manual = "g-2026-11-21-rework"
        func write(_ thread: String, goal: String, lines: [String], files: [String: String] = [:]) throws {
            let dir = project.threadDirectory(thread)
            let reviews = dir.appendingPathComponent("pr-review")
            try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
            try goal.write(to: project.goalURL(thread), atomically: true, encoding: .utf8)
            try (lines.joined(separator: "\n") + "\n").write(to: project.eventsURL(thread), atomically: true, encoding: .utf8)
            for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        }
        // The follow-up's branch, with one commit, cut from main: the report reads its commit subjects with `git log`.
        let cut = try await shipOut(["rev-parse", "HEAD"], fx.repo, fx)
        _ = try await shipOut(["checkout", "-q", "-b", "workbench/\(follow)"], fx.repo, fx)
        try "fix\n".write(to: fx.repo.appendingPathComponent("fix.txt"), atomically: true, encoding: .utf8)
        _ = try await shipOut(["add", "fix.txt"], fx.repo, fx)
        let commit = ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "fix: the real bug"]
        _ = try await shipOut(commit, fx.repo, fx)
        _ = try await shipOut(["checkout", "-q", "-"], fx.repo, fx)
        let judge = #"{"ok":true,"criteria":[{"id":"c1","met":true,"evidence":[]},{"id":"c2","met":false,"evidence":[]}],"#
            + #""concerns":["It may be slow."],"cost_usd":0.1}"#
        try write(
            root, goal: goalFile(root, title: "Add the thing"),
            lines: [
                line(1, 0, "thread.created"), line(2, 1, "turn.started"),
                line(3, 1, "turn.ended", #"{"result":"succeeded","cost_usd":1.0,"summary":"Built the thing."}"#),
                line(4, 1, "check.ran", #"{"result":"passed"}"#), line(5, 1, "judge.ran", judge),
                line(6, 0, "pr.opened", #"{"number":7,"url":"https://example.test/pull/7","head_sha":"abc"}"#),
                line(7, 0, "pr_review.started", #"{"round":1,"pr":7}"#),
                line(
                    8, 0, "pr_review.finished",
                    #"{"round":1,"pr":7,"ok":true,"verdict":"fix","findings_path":"pr-review/round-1.findings.md"}"#),
            ],
            files: [
                "pr-review/round-1.findings.md":
                    "- **[P1] A real bug.** It breaks.\n- **[P2] A missing test.** Add one.\n\nVERDICT: FIX\n"
            ])
        try write(
            follow,
            goal: goalFile(
                follow, title: "Follow-up", pushTo: "workbench/\(root)",
                request: "A second reviewer read the pull request (review round 1) and found problems."),
            lines: [
                line(
                    1, 0, "thread.created", #"{"parent":"\#(root)","root":"\#(root)","round":1}"#),
                line(2, 0, "worktree.created", #"{"base_commit":"\#(cut)"}"#),
                line(3, 1, "turn.started"),
                line(4, 1, "turn.ended", #"{"result":"succeeded","cost_usd":0.5,"summary":"Fixed the bug. Left the test."}"#),
                line(5, 0, "pr_review.started", #"{"round":2,"pr":7}"#),
                line(
                    6, 0, "pr_review.finished",
                    #"{"round":2,"pr":7,"ok":true,"verdict":"clean","findings_path":"pr-review/round-2.findings.md"}"#),
            ],
            files: ["pr-review/round-2.findings.md": "No findings.\nVERDICT: CLEAN\n"])
        try write(
            manual, goal: goalFile(manual, title: "Rework", pushTo: "workbench/\(root)"),
            lines: [
                line(1, 0, "thread.created"), line(2, 1, "turn.started"),
                line(3, 1, "turn.ended", #"{"result":"succeeded","cost_usd":0.25,"summary":"Removed the job."}"#),
            ])
        let directory = project.seriesDirectory("s")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nbudget_usd: 10.00\n---\n## 1\nproject: \(fx.repo.path)\ngoal: g.md\n"
            .write(to: directory.appendingPathComponent("series.md"), atomically: true, encoding: .utf8)
        try goalFile("x", title: "Add the thing")
            .write(to: directory.appendingPathComponent("g.md"), atomically: true, encoding: .utf8)
        try SeriesStepLog(project: project, series: "s").append(SeriesRecord(step: 1, thread: root, at: "t"))
        return (SeriesReporter(library: SeriesLibrary(project: project), git: fx.git, gh: nil), fx)
    }

    @Test func aStepIsReportedFromItsLogsWithRoundsFindingsAndTheFollowUpThatAnsweredThem() async throws {
        let (reporter, _) = try await fixture()
        let report = try await reporter.report("s")
        let step = try #require(report.steps.first)
        #expect(step.goalTitle == "Add the thing" && step.thread == "g-2026-11-21-s-1")
        #expect(step.pullRequest == "https://example.test/pull/7")
        #expect(step.check == "passed after turn 1" && step.judgeTurn == 1)
        #expect(step.criteria.map(\.met) == [true, false] && step.judgeConcerns == ["It may be slow."])
        #expect(step.built == "Built the thing.")
        #expect(step.rounds.map(\.verdict) == ["fix", "clean"])
        #expect(step.rounds[0].findings.map(\.title) == ["A real bug", "A missing test"])
        #expect(step.rounds[0].fix?.thread == "g-2026-11-21-s-1-review-1")
        #expect(step.rounds[0].fix?.said == "Fixed the bug. Left the test.")
        #expect(step.rounds[0].fix?.commits == ["fix: the real bug"])
        #expect(step.rounds[1].fix == nil && step.rounds[1].findings.isEmpty)
        #expect(step.rounds[0].findingsFile == ".workbench/threads/g-2026-11-21-s-1/pr-review/round-1.findings.md")
    }

    @Test func workDoneByHandOnTheBranchIsFoundAndItsCostCounts() async throws {
        let (reporter, _) = try await fixture()
        let step = try #require(try await reporter.report("s").steps.first)
        #expect(step.manual.map(\.thread) == ["g-2026-11-21-rework"])
        #expect(step.manual.first?.said == "Removed the job.")
        // The thread's own 1.00 plus its follow-up's 0.50 plus the hand-made 0.25.
        #expect(abs(step.costUSD - 1.75) < 0.0001)
        // Three coding turns made that cost: the thread's, its review follow-up's and the hand-made one.
        #expect(step.turns == 3)
    }

    @Test func theTotalIsWrittenAgainstTheSeriesBudgetAndAStepNotStartedIsSaidSo() async throws {
        let (reporter, fx) = try await fixture()
        let directory = fx.project.seriesDirectory("s")
        let text = try String(contentsOf: directory.appendingPathComponent("series.md"), encoding: .utf8)
        try (text + "## 2\nproject: \(fx.repo.path)\ngoal: g.md\nafter: 1\n")
            .write(to: directory.appendingPathComponent("series.md"), atomically: true, encoding: .utf8)
        let report = try await reporter.report("s")
        #expect(report.steps.count == 2 && report.steps[1].thread == nil)
        let markdown = report.markdown
        #expect(markdown.contains("$1.75 of the $10.00 series budget"))
        #expect(markdown.contains("Not started."))
    }

    @Test func aCIFixThatTookTheFirstFollowUpNumberDoesNotAnswerTheReviewRound() async throws {
        let (reporter, fx) = try await fixture()
        let project = fx.project
        let root = "g-2026-11-21-s-1"
        // A CI repair was made first (follow-up 1); the review's follow-up is then number 2 although it answers review round 1.
        let ci = "g-2026-11-21-s-1-ci-1"
        let review = "g-2026-11-21-s-1-review-1"
        let dir = project.threadDirectory(ci)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try goalFile(ci, title: "CI", pushTo: "workbench/\(root)", request: "The pull request's checks failed; fix them.")
            .write(to: project.goalURL(ci), atomically: true, encoding: .utf8)
        try (line(1, 0, "thread.created", #"{"parent":"\#(root)","root":"\#(root)","round":1}"#) + "\n"
            + line(2, 1, "turn.started") + "\n"
            + line(3, 1, "turn.ended", #"{"result":"succeeded","cost_usd":0.3,"summary":"Fixed the CI."}"#) + "\n")
            .write(to: project.eventsURL(ci), atomically: true, encoding: .utf8)
        // The review's follow-up now reads as round 2 of the loop.
        let events = try String(contentsOf: project.eventsURL(review), encoding: .utf8)
            .replacingOccurrences(of: #""round":1}"#, with: #""round":2}"#)
        try events.write(to: project.eventsURL(review), atomically: true, encoding: .utf8)

        let step = try #require(try await reporter.report("s").steps.first)
        #expect(step.rounds[0].fix?.thread == review)
        #expect(step.manual.map(\.thread).contains(ci))
        #expect(step.manual.first { $0.thread == ci }?.said == "Fixed the CI.")
        // Counted once: 1.00 + 0.50 + 0.30 + the hand-made 0.25.
        #expect(abs(step.costUSD - 2.05) < 0.0001)
    }

    @Test func aTurnThatReportedNoCostMakesTheStepsCostAtLeastTheFigure() async throws {
        let (reporter, fx) = try await fixture()
        let root = "g-2026-11-21-s-1"
        // A Codex turn reports usage but no dollar figure.
        let extra = line(9, 2, "turn.started") + "\n" + line(10, 2, "turn.ended", #"{"result":"succeeded"}"#) + "\n"
        let url = fx.project.eventsURL(root)
        try (String(contentsOf: url, encoding: .utf8) + extra).write(to: url, atomically: true, encoding: .utf8)
        let step = try #require(try await reporter.report("s").steps.first)
        #expect(step.costUnknown)
    }
}
