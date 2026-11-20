import Foundation
import Testing

@testable import WorkbenchCore

private let criteria = "A unit is gated when its new version depends on a setting that is not enabled."

private func units(_ ids: String...) -> [TaskUnit] { ids.map { TaskUnit(id: $0, title: "\($0) title") } }

private struct Verdict {
    let id: String
    let verdict: String
    let reason: String?
}

// swiftlint:disable:next large_tuple
private func verdictJSON(_ entries: [(String, String, String?)], concerns: [String] = []) -> String {
    let rows = entries.map { Verdict(id: $0.0, verdict: $0.1, reason: $0.2) }.map {
        "{\"id\": \"\($0.id)\", \"verdict\": \"\($0.verdict)\"" + ($0.reason.map { ", \"reason\": \"\($0)\"" } ?? "") + "}"
    }
    let list = concerns.map { "\"\($0)\"" }.joined(separator: ", ")
    return "{\"units\": [\(rows.joined(separator: ", "))], \"concerns\": [\(list)]}"
}

// MARK: the task file, the approval, the answer

@Suite struct TaskGateFileTests {
    private func parse(_ front: String, body: String = "Bump the next countries.") throws -> TaskDefinition {
        try TaskDefinition.parse("---\n\(front)\n---\n\(body)\n", name: "bump")
    }

    private func problems(_ front: String, body: String = "Bump the next countries.") -> String {
        do {
            _ = try parse(front, body: body)
            return ""
        } catch { return "\(error)" }
    }

    @Test func gateInlineTakesItsCriteriaFromTheBodyAndHidesThemFromTheWorker() throws {
        let body = "Bump them.\n\n## Gate\n\(criteria)\nSecond line.\n\n## Notes\nStays with the worker."
        let task = try parse(
            "fix: pr\npending: p.sh\ngate: inline\ngate_allow: [git -C /repo show:*, git -C /repo log:*]\ngate_rounds: 2",
            body: body)
        let allow = ["git -C /repo show:*", "git -C /repo log:*"]
        #expect(task.gate == TaskGate(source: .inline(criteria + "\nSecond line."), allow: allow, rounds: 2))
        #expect(task.instructions == "Bump them.\n\n## Notes\nStays with the worker.")
        #expect(task.gate?.effectiveRounds == 2)
    }

    @Test func gateFileNamesAFileAndNeedsNoSection() throws {
        let task = try parse("fix: pr\npending: p.sh\ngate: .workbench/gate.md")
        #expect(task.gate?.source == .file(".workbench/gate.md") && task.gate?.effectiveRounds == TaskGate.defaultRounds)
        #expect(task.instructions == "Bump the next countries.")
    }

    @Test func aTaskWithoutAGateIsAsItWas() throws {
        // A `## Gate` heading is the worker's own text unless `gate: inline` says it is the criteria.
        let text = "Do it.\n\n## Gate\nnot a gate without the key"
        let task = try parse("fix: pr\npending: p.sh", body: text)
        #expect(task.gate == nil && task.instructions == text)
        let named = try parse("fix: pr\npending: p.sh\ngate: x.md", body: text)
        #expect(named.gate?.source == .file("x.md") && named.instructions == text)
    }

    @Test func badGateSettingsAreRefusedWithTheirKey() {
        let base = "pending: p.sh\n"
        #expect(problems("fix: report\ngate: x.md").contains("'gate' is for 'fix: pr'"))
        #expect(problems("fix: update\npending: p.sh\nbatch: 1\ngate: x.md").contains("'gate' is for 'fix: pr'"))
        #expect(problems("fix: pr\ngate: x.md").contains("'gate' needs 'pending'"))
        #expect(problems("fix: pr\n\(base)gate: inline").contains("needs a '## Gate' section"))
        #expect(problems("fix: pr\n\(base)gate: ../x.md").contains("'gate' must be 'inline' or a file path"))
        #expect(problems("fix: pr\n\(base)gate_allow: [git show:*]").contains("'gate_allow' is for a task with a 'gate'"))
        #expect(problems("fix: pr\n\(base)gate_rounds: 2").contains("'gate_rounds' is for a task with a 'gate'"))
        #expect(problems("fix: pr\n\(base)run_budget: 5").contains("'run_budget' is for a task with a 'gate'"))
        #expect(problems("fix: pr\n\(base)gate: x.md\ngate_rounds: 9").contains("'gate_rounds' must be a whole number from 1"))
        #expect(problems("fix: pr\n\(base)gate: x.md\nrun_budget: -1").contains("'run_budget' must be a positive number"))
        // A command pattern is words and a final `:*`; anything a shell would read as more is refused.
        for bad in ["git show; rm x", "git show $(x)", "git show | cat", "git * show", "git show:*:*", "git `x`", "git > x"] {
            #expect(problems("fix: pr\n\(base)gate: x.md\ngate_allow: [\(bad)]").contains("'gate_allow' has"), "\(bad)")
        }
        #expect(problems("fix: pr\n\(base)gate: x.md\ngate_allow: [git show:*, git show:*]").contains("names a command twice"))
        #expect(problems("fix: pr\n\(base)gate: inline", body: "## Gate\ncriteria").contains("no instructions besides"))
    }

    @Test func aGateFileIsBounded() throws {
        let fx = try TaskFixture(front: "fix: pr\npending: p.sh\ngate: gate.md")
        try fx.script("echo '[]'", as: "p.sh")
        try fx.write("gate.md", criteria)
        #expect(try fx.library.load(fx.name).gateText == Data(criteria.utf8))
        try fx.write("gate.md", String(repeating: "x", count: TaskFiles.maxIncludeBytes + 1))
        #expect(throws: (any Error).self) { try fx.library.load(fx.name) }
    }

    @Test func theApprovalBindsTheGateOnlyWhenThereIsOne() throws {
        let plain = try parse("fix: pr\npending: p.sh")
        let before = TaskApproval.hash(task: plain, pendingScript: nil)
        func hash(_ front: String, gate: String = criteria, body: String = "Bump.") throws -> String {
            let task = try parse(front, body: body + "\n\n## Gate\n" + gate)
            return TaskApproval.hash(task: task, pendingScript: nil, gate: Data(gate.utf8))
        }
        let inline = "fix: pr\npending: p.sh\ngate: inline"
        let base = try hash(inline)
        #expect(base != before)
        // Anything the gate does is part of what is approved: the criteria, the commands, the rounds, the run's budget.
        #expect(try hash(inline, gate: criteria + " More.") != base)
        #expect(try hash(inline + "\ngate_allow: git show:*") != base)
        #expect(try hash(inline + "\ngate_rounds: 2") != base)
        #expect(try hash(inline + "\nrun_budget: 20") != base)
        #expect(try hash(inline + "\ngate_allow: git show:*") != hash(inline + "\ngate_allow: git log:*"))
        #expect(try hash(inline) == base)
        // A task without any of it keeps the hash it had.
        #expect(TaskApproval.hash(task: plain, pendingScript: nil) == before)
    }

    @Test func theAnswerNamesEveryCandidateOnceWithAVerdict() throws {
        let asked = units("ROU", "TUR")
        let good = verdictJSON(
            [("TUR", "gated", "changelog: needs flag x"), ("ROU", "clear", "no flag")], concerns: ["one thing"])
        let verdict = try TaskGateCheck.verdict(fromAnswer: good, units: asked)
        #expect(verdict.units.map(\.id) == ["ROU", "TUR"], "in the order they were asked")
        #expect(verdict.units.map(\.clear) == [true, false] && verdict.concerns == ["one thing"])
        // Fenced JSON is read as the judge's is.
        #expect((try? TaskGateCheck.verdict(fromAnswer: "```json\n\(good)\n```", units: asked)) != nil)

        func refused(_ text: String) -> String? {
            do {
                _ = try TaskGateCheck.verdict(fromAnswer: text, units: asked)
                return nil
            } catch { return "\(error)" }
        }
        #expect(refused("not json")?.contains("not a JSON object") == true)
        #expect(refused("{\"concerns\": []}")?.contains("no list of units") == true)
        let noConcerns =
            "{\"units\": [{\"id\": \"ROU\", \"verdict\": \"clear\"}, {\"id\": \"TUR\", \"verdict\": \"clear\"}]}"
        #expect(refused(noConcerns)?.contains("no list of strings 'concerns'") == true, "required, as the judge's")
        #expect(refused(verdictJSON([("ROU", "clear", "ok")]))?.contains("no verdict for [TUR]") == true)
        let twice = verdictJSON([("ROU", "clear", "ok"), ("TUR", "clear", "ok"), ("ROU", "clear", "ok")])
        #expect(refused(twice)?.contains("twice") == true)
        #expect(refused(verdictJSON([("ROU", "clear", "ok"), ("PAN", "clear", "ok")]))?.contains("was not a candidate") == true)
        #expect(refused(verdictJSON([("ROU", "keep", "ok"), ("TUR", "clear", "ok")]))?.contains("'clear' or 'gated'") == true)
        #expect(refused(verdictJSON([("ROU", "gated", nil), ("TUR", "clear", "ok")]))?.contains("gated without a reason") == true)
        let blank = verdictJSON([("ROU", "gated", "  "), ("TUR", "clear", "ok")])
        #expect(refused(blank)?.contains("gated without a reason") == true)
        // A clear unit needs no reason.
        #expect(refused(verdictJSON([("ROU", "clear", nil), ("TUR", "clear", nil)])) == nil)
    }

    @Test func thePromptFencesTheUnitsAndKeepsTheCriteriaApart() {
        let text = TaskGateCheck.prompt(criteria: criteria, units: units("ROU"), boundary: "abcdef0123456789")
        #expect(text.contains("## Criteria\n\n\(criteria)"))
        #expect(text.contains("=====abcdef012345===== units\n- ROU: ROU title\n=====abcdef012345===== end units"))
    }

    @Test func aHeldUnitIsNeverPendingWhateverElseIsKnownOfIt() async throws {
        let fx = try TaskFixture(front: "fix: pr\npending: p.sh\ngate: inline", body: "x\n\n## Gate\n\(criteria)")
        let writer = try await fx.log.openWriter()
        try await writer.append(
            .taskUnitHeld, data: ["unit": "TUR", "title": "Turkey v1 -> v2", "reason": "flag x", "round": 1])
        try await writer.append(.taskUnitCleared, data: ["unit": "ROU", "title": "Romania", "reason": "ok", "round": 1])
        let history = try fx.log.history()
        #expect(history.held.map(\.id) == ["TUR"] && history.held.first?.title == "Turkey v1 -> v2")
        #expect(history.cleared == ["ROU"])
        let all = units("ROU", "TUR", "PAN")
        let picked = PendingUnits.select(units: all, history: history, pullRequests: [:], batch: 3)
        #expect(picked.map(\.id) == ["ROU", "PAN"])
        // Even a unit GitHub says has no pull request, which would bring it back, stays out while it is held.
        let again = PendingUnits.select(units: all, history: history, pullRequests: ["TUR": .absent, "ROU": .closed], batch: 3)
        #expect(again.map(\.id) == ["ROU", "PAN"])
        // A release, or a later verdict, ends the hold.
        try await writer.append(.taskUnitReleased, data: ["unit": "TUR", "why": "person"])
        await writer.close()
        #expect(try fx.log.history().held.isEmpty)
    }

    @Test func aGateTurnMayRunOnlyTheCommandsItWasGiven() throws {
        let config = try Config.parse("[tools]\navailable = [\"Read\"]\n")
        let agent = ClaudeReadOnlyAgent(config: config, environment: [:])
        let folder = URL(fileURLWithPath: "/tmp/x")
        var request = ReadOnlyRequest(
            prompt: "p", workingDirectory: folder, model: nil, budget: 1, timeout: 60, tools: .read, turn: "gate")
        let bare = agent.arguments(for: request)
        #expect(!bare.contains("Bash") && bare.contains("--tools"))
        request.bash = ["git -C /repo show:*"]
        let args = agent.arguments(for: request)
        let tools = args[(args.firstIndex(of: "--tools")! + 1)..<args.firstIndex(of: "--allowedTools")!]
        let allowed = args[(args.firstIndex(of: "--allowedTools")! + 1)..<args.firstIndex(of: "--")!]
        #expect(Array(tools) == ["Read", "Grep", "Glob", "Bash"])
        #expect(Array(allowed) == ["Read", "Grep", "Glob", "Bash(git -C /repo show:*)"], "Bash only through the pattern")
        #expect(!args.contains("Edit") && !args.contains("Write") && !args.contains("--permission-mode"))
    }
}

// MARK: a run with a gate

/// A `fix: pr` task with a gate, in a project with a real repository, the fake claude (answering one read-only turn after another from
/// a folder of answers) and a fake gh.
private struct Gated {
    let fx: RunnerFixture
    let task: TaskFixture
    let gh: FakeGH
    let answers: URL

    init(
        front: String = "batch: 2\ngate_rounds: 3", pending: [String] = ["ROU", "TUR", "PAN"], extraConfig: String = ""
    ) async throws {
        fx = try await RunnerFixture(extraConfig: "max_active_threads = 1\ncheck_command = \"true\"\n" + extraConfig)
        task = try TaskFixture(
            in: fx.project, front: "fix: pr\npending: pending.sh\ngate: inline\n" + front,
            body: "Bump the next countries.\n\n## Gate\n\(criteria)")
        gh = try FakeGH(in: fx)
        answers = fx.repo.deletingLastPathComponent().appendingPathComponent("answers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        try setPending(pending)
        try await task.library.approve(task.name)
    }

    func setPending(_ ids: [String]) throws {
        let list = ids.map { "{\"id\":\"\($0)\",\"title\":\"\($0) v1 -> v2\"}" }.joined(separator: ",")
        try task.script("echo '[\(list)]'")
    }

    /// The answers the fake claude gives the read-only turns, in order: the gate's, then the pull request's description.
    func answer(_ texts: String...) throws {
        try? FileManager.default.removeItem(at: answers)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        for (i, text) in texts.enumerated() {
            try text.write(to: answers.appendingPathComponent("\(i + 1).txt"), atomically: true, encoding: .utf8)
        }
    }

    static let description = #"{"title": "chore: bump countries", "summary": "Bumps them.", "decisions": [], "deviations": []}"#

    /// How many read-only turns the fake claude has answered.
    var asked: Int {
        (try? String(contentsOf: answers.appendingPathComponent("count"), encoding: .utf8)).flatMap { Int($0) } ?? 0
    }

    func runner(work: Bool = true, dry: Bool = false) -> TaskRunner {
        var runner = TaskRunner(project: fx.project, git: fx.git, gh: gh.runner)
        runner.runOptions = fx.options((work ? "write=a.txt," : "") + "answers=\(answers.path)")
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        runner.retryDelay = .zero
        runner.dryRun = dry
        return runner
    }

    func events(_ kind: EventKind? = nil) throws -> [Event] {
        let all = try EventLogReader.read(at: task.log.url).events
        return kind.map { kind in all.filter { $0.kind == kind } } ?? all
    }

    func threads() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fx.project.threadsDirectory.path)) ?? []).sorted()
    }
}

@Suite(.processGate) struct TaskGateRunTests {
    @Test func aGateThatKeepsEverythingAsksOnceAndTheWorkerTakesTheBatch() async throws {
        let run = try await Gated()
        _ = try await addOrigin(run.fx)
        try run.answer(
            verdictJSON([("ROU", "clear", "no flag in v2"), ("TUR", "clear", "no flag in v2")]), Gated.description)
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .prOpened, "\(result.reason ?? "")")
        #expect(result.units == ["ROU", "TUR"])
        #expect(run.asked == 2, "one gate turn and the description, nothing more")
        #expect(try run.events(.taskRunGate).count == 1 && run.events(.taskUnitCleared).count == 2)
        #expect(try run.events(.taskUnitHeld).isEmpty)
        let history = try run.task.log.history()
        #expect(history.held.isEmpty && history.cleared == ["ROU", "TUR"])
    }

    @Test func aGatedUnitIsHeldAndTheBatchIsToppedUpAndAskedAboutAgain() async throws {
        let run = try await Gated()
        _ = try await addOrigin(run.fx)
        try run.answer(
            verdictJSON([("ROU", "clear", "no flag"), ("TUR", "gated", "changelog v2: 'needs flag tur_x' (off)")]),
            verdictJSON([("PAN", "clear", "no flag")]), Gated.description)
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .prOpened, "\(result.reason ?? "")")
        #expect(result.units == ["ROU", "PAN"], "the worker never saw TUR")
        #expect(run.asked == 3, "two gate turns and the description")
        let held = try run.task.log.history().held
        #expect(held.map(\.id) == ["TUR"] && held.first?.reason.contains("tur_x") == true && held.first?.title == "TUR v1 -> v2")

        // In the log: every verdict before the thread exists, so a unit is never both held and taken.
        let kinds = try run.events().map(\.kind.rawValue)
        let thread = try #require(kinds.firstIndex(of: "task.run.thread"))
        for kind in ["task.unit.held", "task.unit.cleared", "task.run.gate"] {
            #expect(kinds.enumerated().filter { $1 == kind }.allSatisfy { $0.offset < thread }, "\(kind) comes before the thread")
        }
        let rounds = try run.events(.taskRunGate)
        #expect(rounds.map { $0.data["round"] } == [.int(1), .int(2)])
        #expect(rounds[0].data["gated"]?.arrayItems?.first?["unit"]?.stringValue == "TUR")
        let taken = try #require(run.events(.taskRunThread).first)
        #expect(taken.data["units"]?.arrayItems?.compactMap(\.stringValue) == ["ROU", "PAN"])
    }

    @Test func aGateThatHoldsEverythingStartsNoThreadAndNoPullRequest() async throws {
        let run = try await Gated()
        try run.answer(
            verdictJSON([("ROU", "gated", "flag a is off"), ("TUR", "gated", "flag b is off")]),
            verdictJSON([("PAN", "gated", "flag c is off")]))
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .nothingToDo && result.thread == nil && result.pullRequest == nil && result.units.isEmpty)
        let reason = result.reason ?? ""
        let expectations = ["ROU (flag a is off)", "TUR (flag b is off)", "PAN (flag c is off)", "no more candidates"]
        for expected in expectations {
            #expect(reason.contains(expected), "\(reason)")
        }
        #expect(run.threads().isEmpty, "no thread was made")
        #expect(try run.task.log.history().held.map(\.id) == ["ROU", "TUR", "PAN"])

        // The next run has nothing to offer, says why, and does not ask the gate again.
        try run.answer()
        let again = await run.runner().run("bump", trigger: .manual)
        #expect(again.outcome == .nothingPending && again.reason?.contains("3 held by the gate") == true)
        #expect(run.asked == 0)
    }

    @Test func theRoundLimitShipsWhatWasClearAndSaysSo() async throws {
        let run = try await Gated(front: "batch: 2\ngate_rounds: 1")
        _ = try await addOrigin(run.fx)
        try run.answer(
            verdictJSON([("ROU", "gated", "flag a is off"), ("TUR", "clear", "no flag")]), Gated.description)
        let said = Said()
        var runner = run.runner()
        runner.notice = { said.add($0) }
        let result = await runner.run("bump", trigger: .manual)
        #expect(result.outcome == .prOpened && result.units == ["TUR"], "\(result.reason ?? "")")
        #expect(run.asked == 2, "no second gate turn")
        #expect(said.lines.contains { $0.contains("the round limit (gate_rounds) was reached") })
    }

    @Test func anAnswerThatIsNotUsableFailsTheRunBeforeAnythingIsStarted() async throws {
        let run = try await Gated()
        try run.answer(verdictJSON([("ROU", "gated", nil), ("TUR", "clear", "ok")]))
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.thread == nil)
        let reason = result.reason ?? ""
        #expect(reason.contains("the gate could not decide") && reason.contains("without a reason"))
        #expect(run.threads().isEmpty)
        #expect(try run.events(.taskUnitHeld).isEmpty && run.events(.taskUnitCleared).isEmpty, "nothing recorded")
        #expect(try run.task.log.history().runs.last?.outcome == .failed)
    }

    @Test func aClearedUnitIsNotAskedAboutAgainAndARunThatFailedMidGateKeepsWhatItLearned() async throws {
        let run = try await Gated()
        _ = try await addOrigin(run.fx)
        // Round 1 decides ROU and TUR; round 2's answer is not JSON, so the run fails with those two verdicts on record.
        try run.answer(
            verdictJSON([("ROU", "clear", "no flag"), ("TUR", "gated", "flag t is off")]), "no json at all")
        let failed = await run.runner().run("bump", trigger: .manual)
        #expect(failed.outcome == .failed && failed.thread == nil)
        let history = try run.task.log.history()
        #expect(history.cleared == ["ROU"] && history.held.map(\.id) == ["TUR"])

        // The next run asks only about what it does not know: PAN. An answer that also covered ROU would be refused.
        try run.answer(verdictJSON([("PAN", "clear", "no flag")]), Gated.description)
        let next = await run.runner().run("bump", trigger: .manual)
        #expect(next.outcome == .prOpened && next.units == ["ROU", "PAN"], "\(next.reason ?? "")")
        #expect(run.asked == 2)
    }

    @Test func aDryRunAsksTheGateAndWritesNoVerdicts() async throws {
        let run = try await Gated()
        try run.answer(
            verdictJSON([("ROU", "clear", "no flag"), ("TUR", "gated", "flag t is off")]), verdictJSON([("PAN", "clear", "ok")]))
        let said = Said()
        var runner = run.runner(dry: true)
        runner.notice = { said.add($0) }
        let result = await runner.run("bump", trigger: .manual)
        #expect(result.outcome == .reported && result.units == ["ROU", "PAN"] && result.thread == nil)
        #expect(result.reason == "dry run (gate): would take ROU, PAN; held: TUR (flag t is off)")
        #expect(said.lines.contains { $0.contains("gate: TUR held: flag t is off") })
        for kind in [EventKind.taskUnitHeld, .taskUnitCleared, .taskRunGate, .taskUnitReleased] {
            #expect(try run.events(kind).isEmpty, "\(kind.rawValue)")
        }
        #expect(run.threads().isEmpty && run.asked == 2)
        #expect(try run.task.log.history().held.isEmpty)
    }

    @Test func aUnitTheScriptStopsListingIsForgotten() async throws {
        let run = try await Gated()
        try run.answer(
            verdictJSON([("ROU", "gated", "flag a is off"), ("TUR", "gated", "flag b is off")]),
            verdictJSON([("PAN", "gated", "flag c is off")]))
        _ = await run.runner().run("bump", trigger: .manual)
        #expect(try run.task.log.history().held.map(\.id) == ["ROU", "TUR", "PAN"])

        // A newer version has a new id: the old one is gone from the list, and so from the held units.
        try run.setPending(["ROU", "TUR", "PAN2"])
        try await run.task.library.approve("bump")
        try run.answer(verdictJSON([("PAN2", "gated", "flag d is off")]))
        _ = await run.runner().run("bump", trigger: .manual)
        let released = try run.events(.taskUnitReleased)
        #expect(released.compactMap { $0.data["unit"]?.stringValue } == ["PAN"])
        #expect(released.first?.data["why"]?.stringValue == "no longer listed")
        #expect(try run.task.log.history().held.map(\.id) == ["ROU", "TUR", "PAN2"])
    }

    @Test func aPersonReleasesAHeldUnitAndTheNextRunOffersItAgain() async throws {
        let run = try await Gated(front: "batch: 1\ngate_rounds: 1", pending: ["ROU"])
        try run.answer(verdictJSON([("ROU", "gated", "flag a is off")]))
        _ = await run.runner().run("bump", trigger: .manual)
        #expect(try run.task.log.history().held.map(\.id) == ["ROU"])

        do {
            try await run.task.library.release("TUR", of: "bump")
            Issue.record("a unit that is not held was released")
        } catch let error as TaskStateError { #expect(error == .notHeld("TUR")) }
        do {
            try await run.task.library.release("ROU", of: "nothing")
            Issue.record("a task that is not there")
        } catch let error as TaskStateError { #expect(error == .notFound("nothing")) }
        try await run.task.library.release("ROU", of: "bump")
        #expect(try run.task.log.history().held.isEmpty)
        #expect(try run.events(.taskUnitReleased).first?.data["why"]?.stringValue == "person")

        try run.answer(verdictJSON([("ROU", "gated", "flag a is still off")]))
        let again = await run.runner().run("bump", trigger: .manual)
        #expect(again.outcome == .nothingToDo && run.asked == 1, "the released unit was asked about again")
    }

    @Test func aRunThatDiedInTheGateHoldsNoUnitAndTakesNone() async throws {
        let run = try await Gated()
        // What a killed run leaves: its start, a verdict that held one unit and cleared another, and no end.
        let writer = try await run.task.log.openWriter()
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(
            .taskUnitHeld, data: ["unit": "TUR", "title": "TUR v1 -> v2", "reason": "flag t is off", "round": 1])
        try await writer.append(.taskUnitCleared, data: ["unit": "ROU", "title": "ROU v1 -> v2", "reason": "no flag", "round": 1])
        await writer.close()
        #expect(try run.task.log.history().openRun != nil)

        // The next writer closes it as interrupted, with no thread and no unit: nothing was taken, nothing is lost.
        let next = try await run.task.log.openWriter()
        await next.close()
        let history = try run.task.log.history()
        let died = try #require(history.runs.first)
        #expect(died.outcome == .interrupted && died.thread == nil && died.units.isEmpty)
        #expect(history.held.map(\.id) == ["TUR"] && history.cleared == ["ROU"])
        #expect(history.unitsWithThreads.isEmpty && history.failedTries.isEmpty)
        let pending = PendingUnits.select(
            units: units("ROU", "TUR", "PAN"), history: history, pullRequests: [:], batch: 3)
        #expect(pending.map(\.id) == ["ROU", "PAN"], "held and pending never overlap")
    }

    @Test func aRunBudgetBelowTheWorkersBudgetIsRefusedBeforeAnythingIsSpent() async throws {
        // The worker alone may spend the project's default budget (1.00): a run budget under it could not be kept.
        let run = try await Gated(front: "batch: 2\nrun_budget: 0.50")
        try run.answer(verdictJSON([("ROU", "clear", "ok"), ("TUR", "clear", "ok")]))
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("run_budget 0.5 is less than the worker's budget 1") == true)
        #expect(run.asked == 0 && run.threads().isEmpty)
    }

    @Test func aGateOnCodexIsRefusedBecauseItCannotBeHeldToAToolList() async throws {
        let run = try await Gated(extraConfig: "\n[agents.judge]\nprovider = \"codex\"\nallow_unpriced = true\n")
        try run.answer(verdictJSON([("ROU", "clear", "ok"), ("TUR", "clear", "ok")]))
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .failed && result.reason?.contains("a gate needs Claude") == true, "\(result.reason ?? "")")
        #expect(run.asked == 0 && run.threads().isEmpty)
    }

    @Test func aHeldUnitIsForgottenEvenWhenTheScriptListsNothingAtAll() async throws {
        let run = try await Gated(front: "batch: 1\ngate_rounds: 1", pending: ["TUR"])
        try run.answer(verdictJSON([("TUR", "gated", "flag t is off")]))
        _ = await run.runner().run("bump", trigger: .manual)
        #expect(try run.task.log.history().held.map(\.id) == ["TUR"])

        try run.setPending([])
        try await run.task.library.approve("bump")
        let result = await run.runner().run("bump", trigger: .manual)
        #expect(result.outcome == .nothingPending)
        #expect(try run.events(.taskUnitReleased).first?.data["why"]?.stringValue == "no longer listed")
        #expect(try run.task.log.history().held.isEmpty, "a unit the script no longer names is not held for ever")
    }

    @Test func aTaskWithoutAGateRunsAsItAlwaysDid() async throws {
        let fx = try await RunnerFixture(extraConfig: "max_active_threads = 1\ncheck_command = \"true\"")
        let task = try TaskFixture(in: fx.project, front: "fix: pr\nbatch: 2\npending: pending.sh")
        let gh = try FakeGH(in: fx)
        try task.script(#"echo '[{"id":"ROU"},{"id":"TUR"},{"id":"PAN"}]'"#)
        try await task.library.approve(task.name)
        _ = try await addOrigin(fx)
        let answer = fx.repo.deletingLastPathComponent().appendingPathComponent("answer-\(UUID().uuidString).txt")
        try Gated.description.write(to: answer, atomically: true, encoding: .utf8)
        var runner = TaskRunner(project: fx.project, git: fx.git, gh: gh.runner)
        runner.runOptions = fx.options("write=a.txt", "answer=\(answer.path)")
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let result = await runner.run("bump", trigger: .manual)
        #expect(result.outcome == .prOpened && result.units == ["ROU", "TUR"], "\(result.reason ?? "")")
        let kinds = try EventLogReader.read(at: task.log.url).events.map(\.kind.rawValue)
        #expect(!kinds.contains { $0 == "task.run.gate" || $0 == "task.unit.held" || $0 == "task.unit.cleared" })
    }
}

final class Said: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ line: String) { lock.withLock { items.append(line) } }
    var lines: [String] { lock.withLock { items } }
}
