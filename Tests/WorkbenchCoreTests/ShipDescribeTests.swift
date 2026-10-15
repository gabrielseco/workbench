import Foundation
import Testing

@testable import WorkbenchCore

private struct Described {
    var fx: RunnerFixture
    var plan: ShipPlan
    var config: Config
    var dir: URL

    func file(_ name: String, _ text: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func environment(_ directives: String...) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE": directives.joined(separator: ",")]
    }
}

private func described() async throws -> Described {
    let fx = try await RunnerFixture()
    let (id, _) = try await acceptedThread(fx)
    _ = try await addOrigin(fx)
    let gh = try FakeGH(in: fx)
    let plan = try await fx.service.shipPreflight(id: id, gh: gh.runner)
    let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("describe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Described(fx: fx, plan: plan, config: try Config.load(from: fx.project.configURL), dir: dir)
}

private let good = """
    {"title": "feat(a): add hello", "summary": "Adds a greeting.", "decisions": ["One file."], "deviations": []}
    """

@Suite struct ShipDescribeTests {
    @Test func aGoodAnswerBecomesTheDescriptionAndIsRecordedAsItsOwnEvent() async throws {
        let d = try await described()
        let turnsBefore = try d.fx.events(d.plan.id).filter { $0.kind == .turnStarted }.count
        let answer = try d.file("answer.txt", good)
        let dump = d.dir.appendingPathComponent("dump.json").path

        let result = try await d.fx.service.describePR(
            plan: d.plan, config: d.config, environment: d.environment("answer=\(answer)", "dump=\(dump)"))
        #expect(result.fallback == nil)
        #expect(result.description?.title == "feat(a): add hello")
        #expect(result.description?.decisions == ["One file."])

        let events = try d.fx.events(d.plan.id)
        let event = try #require(events.last)
        #expect(event.kind == .prDescribed)
        #expect(event.data["ok"] == true)
        #expect(events.filter { $0.kind == .turnStarted }.count == turnsBefore)
        #expect(ThreadStore(project: d.fx.project).state(of: d.plan.id).lastTurn == turnsBefore)

        // No tools, and not the work session.
        let argv = try String(contentsOfFile: dump, encoding: .utf8)
        #expect(argv.contains("\"--tools\""))
        #expect(!argv.contains("--allowedTools") && !argv.contains("--resume"))
        #expect(try d.fx.contents(d.plan.id).isHealthy)
    }

    @Test(arguments: [
        ("not json at all", "", "not a JSON object"),
        (#"{"title":"","summary":"s"}"#, "", "not usable"),
        (good, "exit=1", "status 1"),
    ])
    func anyFailureFallsBackAndSaysWhy(answerText: String, exit: String, why: String) async throws {
        let d = try await described()
        let answer = try d.file("answer.txt", answerText)
        var directives = ["answer=\(answer)"]
        if !exit.isEmpty { directives.append(exit) }

        let result = try await d.fx.service.describePR(
            plan: d.plan, config: d.config,
            environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE": directives.joined(separator: ",")])
        #expect(result.description == nil)
        #expect(try #require(result.fallback).contains(why))
        let event = try #require(try d.fx.events(d.plan.id).last)
        #expect(event.kind == .prDescribed && event.data["ok"] == false)
        #expect(try d.fx.contents(d.plan.id).isHealthy)
    }

    @Test func aMissingClaudeFallsBack() async throws {
        let d = try await described()
        var config = d.config
        config.claudePath = "/nonexistent/claude"
        let result = try await d.fx.service.describePR(plan: d.plan, config: config, environment: ["PATH": "/usr/bin"])
        #expect(result.description == nil)
        #expect(result.fallback?.contains("was not found") == true)
    }

    @Test func aSlowClaudeFallsBackAtTheTimeout() async throws {
        let d = try await described()
        let result = try await d.fx.service.describePR(
            plan: d.plan, config: d.config, environment: d.environment("hang-after=0"), timeout: 1)
        #expect(result.description == nil)
        #expect(result.fallback?.contains("did not answer within 1s") == true)
    }

    @Test func thePRBodyUsesTheDescriptionAndStillReportsTheRealCheck() async throws {
        let d = try await described()
        let description = PRDescription(
            title: "feat(a): add hello", summary: "Adds a greeting. All criteria pass.", decisions: ["One file."],
            deviations: [])
        let body = try await d.fx.service.prBody(plan: d.plan, description: description, environment: [:])
        #expect(body.title == "feat(a): add hello")
        #expect(body.body.contains("Adds a greeting."))
        #expect(body.body.contains("### Decisions to review"))
        #expect(body.body.contains("- [ ] "))
        #expect(!body.body.contains("TODO(workbench)"))

        let fallback = try await d.fx.service.prBody(plan: d.plan, description: nil, environment: [:])
        #expect(fallback.title == "work")
    }

    @Test func theDescriptionReachesGhCreate() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, _) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        _ = try await fx.service.shipPush(id: id, gh: gh.runner)
        let description = PRDescription(
            title: "feat(a): add hello", summary: "Adds a greeting.", decisions: [], deviations: [])

        _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner, description: description)
        let create = try #require(gh.calls.first { $0.hasPrefix("pr create") })
        #expect(create.contains("--title=feat(a): add hello"))
        #expect(try #require(gh.read("body")).contains("Adds a greeting."))
    }
}
