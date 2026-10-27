import Foundation
import Testing

@testable import WorkbenchCore

private let currentTitle = "chore: bump five countries"

private func listJSON(title: String, body: String, head: String) throws -> String {
    let item: [String: Any] = [
        "number": 12, "url": "https://github.com/o/r/pull/12", "headRefName": "feature/pr", "baseRefName": "main",
        "headRefOid": head, "title": title, "body": body,
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: [item]), as: UTF8.self)
}

private struct Refresh {
    var fx: RunnerFixture
    var thread: UpdateThread
    var gh: FakeGH
    var head: String
    var dir: URL

    func publish(title: String = currentTitle, body: String = sampleBody) throws {
        try gh.put("list", try listJSON(title: title, body: body, head: head))
    }

    func file(_ name: String, _ text: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func environment(_ directives: String...) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE": directives.joined(separator: ",")]
    }

    func plan() async throws -> ShipPlan { try await fx.service.shipPreflight(id: thread.id, gh: gh.runner) }
}

private func refresh() async throws -> Refresh {
    let fx = try await RunnerFixture()
    let thread = try await acceptedUpdateThread(fx)
    let gh = try FakeGH(in: fx)
    let head = try await shipOut(["rev-parse", "HEAD"], thread.worktree, fx)
    let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("refresh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let r = Refresh(fx: fx, thread: thread, gh: gh, head: head, dir: dir)
    try r.publish()
    return r
}

private let fourCountries = """
    {"title": "chore: bump four countries", "sections": {"Summary": "Moves four countries to their latest version."}}
    """

@Suite(.processGate) struct ShipRefreshTests {
    @Test func theProposalChangesOnlyWhatTheAnswerNamesAndIsRecorded() async throws {
        let r = try await refresh()
        let plan = try await r.plan()
        let reply = try r.file("answer.txt", fourCountries)
        let dump = r.dir.appendingPathComponent("dump.json").path

        let result = try await r.fx.service.proposePRRefresh(
            plan: plan, config: try Config.load(from: r.fx.project.configURL),
            environment: r.environment("answer=\(reply)", "dump=\(dump)"))
        let proposal = try #require(result.proposal)
        #expect(result.fallback == nil && proposal.number == 12 && proposal.titleChanged)
        #expect(proposal.updated.title == "chore: bump four countries")
        #expect(proposal.updated.body.contains("Moves four countries"))
        #expect(proposal.updated.body.contains("These five countries were behind."), "Why is untouched")
        #expect(proposal.updated.body.hasSuffix("<!-- /CURSOR_SUMMARY -->"), "the bot block is still last")
        #expect(proposal.changes.map(\.heading) == ["## Summary"])
        #expect(proposal.render().contains("  + Moves four countries to their latest version."))

        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("\"--tools\"") && !argv.contains("--allowedTools") && !argv.contains("--resume"))
        let event = try #require(try r.fx.events(r.thread.id).last)
        #expect(event.kind == .prRefreshed && event.data["stage"]?.stringValue == "proposed" && event.data["ok"] == true)
    }

    @Test func theShipModelReachesTheRefreshTurnAndWithoutItNoModelIsPassed() async throws {
        let r = try await refresh()
        let plan = try await r.plan()
        let reply = try r.file("answer.txt", fourCountries)
        for model in ["haiku", nil] as [String?] {
            var config = try Config.load(from: r.fx.project.configURL)
            config.agents.ship.model = model
            let dump = r.dir.appendingPathComponent("dump-\(model ?? "unset").json").path
            _ = try await r.fx.service.proposePRRefresh(
                plan: plan, config: config, environment: r.environment("answer=\(reply)", "dump=\(dump)"))
            let argv = try String(contentsOfFile: dump, encoding: .utf8)
            #expect(argv.contains("\"--model\"") == (model != nil), "\(argv)")
            if let model { #expect(argv.contains("\"\(model)\""), "\(argv)") }
        }
    }

    @Test func aTurnThatFailsLeavesThePullRequestAloneAndSaysWhy() async throws {
        let r = try await refresh()
        let plan = try await r.plan()
        let reply = try r.file("answer.txt", fourCountries)
        let result = try await r.fx.service.proposePRRefresh(
            plan: plan, config: try Config.load(from: r.fx.project.configURL),
            environment: r.environment("answer=\(reply)", "exit=1"))
        #expect(result.proposal == nil && result.fallback?.contains("status 1") == true)
        #expect(try r.fx.events(r.thread.id).last?.data["ok"] == false)
    }

    @Test func anAnswerThatChangesNothingIsAnEmptyProposal() async throws {
        let r = try await refresh()
        let plan = try await r.plan()
        let same = try r.file("answer.txt", #"{"title": "\#(currentTitle)", "sections": {}}"#)
        let result = try await r.fx.service.proposePRRefresh(
            plan: plan, config: try Config.load(from: r.fx.project.configURL), environment: r.environment("answer=\(same)"))
        #expect(try #require(result.proposal).isEmpty)
    }

    @Test func aTitleTheAnswerLeavesAloneIsNeverRewrittenByScrubbing() async throws {
        let r = try await refresh()
        let title = "fix: handle /api/v1 requests"
        try r.publish(title: title)
        let plan = try await r.plan()
        let same = try r.file("answer.txt", #"{"title": "fix: handle /api/v1 requests", "sections": {}}"#)
        let result = try await r.fx.service.proposePRRefresh(
            plan: plan, config: try Config.load(from: r.fx.project.configURL), environment: r.environment("answer=\(same)"))
        let proposal = try #require(result.proposal)
        #expect(proposal.isEmpty && proposal.updated.title == title)
    }

    @Test func applyingWritesTheTextWithGhAndRecordsIt() async throws {
        let r = try await refresh()
        let plan = try await r.plan()
        let reply = try r.file("answer.txt", fourCountries)
        let proposal = try #require(
            try await r.fx.service.proposePRRefresh(
                plan: plan, config: try Config.load(from: r.fx.project.configURL), environment: r.environment("answer=\(reply)")
            ).proposal)

        try await r.fx.service.applyPRRefresh(id: r.thread.id, plan: plan, proposal: proposal, gh: r.gh.runner)
        #expect(r.gh.count("pr edit 12") == 1)
        #expect(r.gh.read("edit_title")?.trimmingCharacters(in: .whitespacesAndNewlines) == "chore: bump four countries")
        #expect(r.gh.read("edit_body") == proposal.updated.body)
        let event = try #require(try r.fx.events(r.thread.id).last)
        #expect(event.kind == .prRefreshed && event.data["stage"]?.stringValue == "applied")
    }

    @Test func aPullRequestEditedMeanwhileIsNeverOverwritten() async throws {
        let r = try await refresh()
        let plan = try await r.plan()
        let reply = try r.file("answer.txt", fourCountries)
        let proposal = try #require(
            try await r.fx.service.proposePRRefresh(
                plan: plan, config: try Config.load(from: r.fx.project.configURL), environment: r.environment("answer=\(reply)")
            ).proposal)

        try r.publish(body: sampleBody + "\n\nA reviewer added this line.\n")
        do {
            try await r.fx.service.applyPRRefresh(id: r.thread.id, plan: plan, proposal: proposal, gh: r.gh.runner)
            Issue.record("expected a refusal")
        } catch let error as ShipError { #expect(error == .pullRequestTextChanged) }
        #expect(r.gh.count("pr edit") == 0)
    }

    @Test func aFailedEditIsReportedWithAHandEditHint() async throws {
        let r = try await refresh()
        let plan = try await r.plan()
        let reply = try r.file("answer.txt", fourCountries)
        let proposal = try #require(
            try await r.fx.service.proposePRRefresh(
                plan: plan, config: try Config.load(from: r.fx.project.configURL), environment: r.environment("answer=\(reply)")
            ).proposal)
        try r.gh.put("edit_fail", "GraphQL: not allowed\n")
        do {
            try await r.fx.service.applyPRRefresh(id: r.thread.id, plan: plan, proposal: proposal, gh: r.gh.runner)
            Issue.record("expected a failure")
        } catch let error as ShipError {
            guard case .ghEditFailed(let why) = error else {
                Issue.record("got \(error)")
                return
            }
            #expect(why.contains("not allowed"))
        }
        let applied = try r.fx.events(r.thread.id).contains {
            $0.kind == .prRefreshed && $0.data["stage"]?.stringValue == "applied"
        }
        #expect(!applied)
    }

    @Test func yesAloneShowsTheProposalButNeverEditsThePullRequest() async throws {
        let r = try await refresh()
        let reply = try r.file("answer.txt", fourCountries)
        let shipped = try await runShip(["--yes"], fx: r.fx, gh: r.gh, extraEnvironment: ["FAKE_CLAUDE": "answer=\(reply)"])
        #expect(shipped.code == 0, "\(shipped.text)")
        #expect(shipped.text.contains("proposed update to the pull request text"))
        #expect(shipped.text.contains("+ Moves four countries to their latest version."))
        #expect(shipped.text.contains("pass --refresh-description to update it"))
        #expect(r.gh.count("pr edit") == 0)
    }

    @Test func theFlagIsTheExplicitConsentThatEditsIt() async throws {
        let r = try await refresh()
        let reply = try r.file("answer.txt", fourCountries)
        let shipped = try await runShip(
            ["--yes", "--refresh-description"], fx: r.fx, gh: r.gh, extraEnvironment: ["FAKE_CLAUDE": "answer=\(reply)"])
        #expect(shipped.code == 0, "\(shipped.text)")
        #expect(shipped.text.contains("updated the pull request title and description"))
        #expect(r.gh.count("pr edit 12") == 1)
        let body = try #require(r.gh.read("edit_body"))
        #expect(body.contains("Moves four countries") && body.hasSuffix("<!-- /CURSOR_SUMMARY -->"))
    }

    @Test func aFailedEditStillRecordsThePullRequestPrintsItAndFails() async throws {
        let r = try await refresh()
        let reply = try r.file("answer.txt", fourCountries)
        try r.gh.put("edit_fail", "GraphQL: not allowed\n")
        let shipped = try await runShip(
            ["--yes", "--refresh-description"], fx: r.fx, gh: r.gh, extraEnvironment: ["FAKE_CLAUDE": "answer=\(reply)"])
        #expect(shipped.code == 1, "\(shipped.text)")
        #expect(shipped.text.contains("https://github.com/o/r/pull/12") && shipped.text.contains("edit its title and description by hand"))
        #expect(try r.fx.kinds(r.thread.id).contains("pr.opened"))
    }

    @Test func noDescribeSkipsTheProposalEntirely() async throws {
        let r = try await refresh()
        let dump = r.dir.appendingPathComponent("dump.json").path
        let reply = try r.file("answer.txt", fourCountries)
        let shipped = try await runShip(
            ["--yes", "--refresh-description", "--no-describe"], fx: r.fx, gh: r.gh,
            extraEnvironment: ["FAKE_CLAUDE": "answer=\(reply),dump=\(dump)"])
        #expect(shipped.code == 0, "\(shipped.text)")
        #expect(!FileManager.default.fileExists(atPath: dump))
        #expect(r.gh.count("pr edit") == 0)
    }
}
