import Foundation
import Testing

@testable import WorkbenchCore

/// `workbench ship` and `workbench plan` through the binary, on Claude and on Codex: `stop` reaches a description or
/// refresh turn, `plan` says what bounds it, and a Codex description is shown in full before the push.

private let goodDescription = """
    {"title": "feat(a): add hello", "summary": "Adds a greeting.", "decisions": [], "deviations": []}
    """

private let fourCountries = """
    {"title": "chore: bump four countries", "sections": {"Summary": "Moves four countries to their latest version."}}
    """

/// Text the refresh leaves alone: shown only when the whole body is printed, not in the list of changes.
private let untouched = "These five countries were behind."

private func appendConfig(_ fx: RunnerFixture, _ text: String) throws {
    let url = fx.project.configURL
    try (try String(contentsOf: url, encoding: .utf8) + "\n" + text).write(to: url, atomically: true, encoding: .utf8)
}

private func onCodex(_ fx: RunnerFixture, _ codex: FakeCodex, role: String) throws {
    try appendConfig(fx, "[providers.codex]\nexecutable = \"\(codex.path)\"\n[agents.\(role)]\nprovider = \"codex\"\n")
}

private struct CLI {
    var fx: RunnerFixture
    var gh: FakeGH?
    var codex: FakeCodex?
    var fakeClaude = ""

    func start(_ arguments: [String]) throws -> ProcessRun {
        var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "FAKE_CLAUDE": fakeClaude]
        if let gh {
            environment["PATH"] = "\(gh.dir.path):/usr/bin:/bin"
            environment["GH_FAKE_DIR"] = gh.dir.path
        }
        if let codex { environment["CODEX_FAKE_DIR"] = codex.dir.path }
        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: arguments, environment: environment,
            workingDirectory: fx.repo, timeout: 120)
        spawn.snapshotInterval = 3600
        return try ProcessRunner.start(spawn)
    }

    func run(_ arguments: [String]) async throws -> Ran {
        let (lines, exit) = await output(of: try start(arguments))
        var code: Int32?
        if case .exited(let c)? = exit?.termination { code = c }
        return Ran(code: code, lines: lines, text: (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
    }
}

private struct Ran {
    var code: Int32?
    var lines: [String]
    /// stdout lines, then what went to stderr.
    var text: String
}

private func output(of run: ProcessRun) async -> ([String], ProcessExit?) {
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    return (lines, exit)
}

/// An accepted thread that updates an open pull request, whose text the refresh turn is asked about.
private func updateThread(_ fx: RunnerFixture, _ gh: FakeGH) async throws -> String {
    let thread = try await acceptedUpdateThread(fx)
    let head = try await shipOut(["rev-parse", "HEAD"], thread.worktree, fx)
    let item: [String: Any] = [
        "number": 12, "url": "https://github.com/o/r/pull/12", "headRefName": "feature/pr", "baseRefName": "main",
        "headRefOid": head, "title": "chore: bump five countries", "body": sampleBody,
    ]
    try gh.put("list", String(decoding: try JSONSerialization.data(withJSONObject: [item]), as: UTF8.self))
    return thread.id
}

private func scratchFile(_ fx: RunnerFixture, _ name: String, _ text: String = "") throws -> URL {
    let url = fx.repo.deletingLastPathComponent().appendingPathComponent("\(name)-\(UUID().uuidString)")
    if !text.isEmpty { try text.write(to: url, atomically: true, encoding: .utf8) }
    return url
}

private struct Failed: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

@Suite(.processGate) struct PRTurnStopTests {
    /// Starts `ship` with an agent that hangs, checks the thread is held, stops it as `workbench stop` does, and checks
    /// what the turn recorded and that the hold is gone.
    private func stopThroughTheHolder(refresh: Bool, provider: AgentProviderID) async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let id: String
        if refresh {
            id = try await updateThread(fx, gh)
        } else {
            id = try await acceptedThread(fx).id
            _ = try await addOrigin(fx)
        }
        let ready = try scratchFile(fx, "ready")
        var cli = CLI(fx: fx, gh: gh, fakeClaude: "hang-after=0,ready=\(ready.path)")
        var started = ready.path
        if provider == .codex {
            let codex = try FakeCodex(in: fx)
            try codex.put("hang", "")
            try onCodex(fx, codex, role: "ship")
            cli.codex = codex
            started = codex.dir.appendingPathComponent("pid").path
        }

        let ship = try cli.start(["ship"])
        let held = await pollUntil {
            fx.service.runnerPID(id: id) == ship.pid && FileManager.default.fileExists(atPath: started)
        }
        try #require(held, "the turn started and the ship process holds the thread")

        // Meanwhile the thread is busy.
        let config = try Config.load(from: fx.project.configURL)
        do {
            _ = try await fx.service.plan(id: id, config: config)
            Issue.record("expected the plan to be refused")
        } catch let error as ThreadServiceError { #expect(error == .running(pid: ship.pid)) }
        do {
            _ = try await fx.service.judge(id: id, config: config)
            Issue.record("expected the judge to be refused")
        } catch let error as ThreadServiceError { #expect(error == .running(pid: ship.pid)) }
        await #expect(throws: (any Error).self, "a run is refused too") { _ = try await fx.runner(id).run(fx.options()) }

        #expect(fx.service.requestStop(id: id) == .signalled(pid: ship.pid))
        let (lines, exit) = await output(of: ship)
        #expect(exit?.cause == .natural, "ship ended by itself after the stop: \(lines)")
        // A stop means "do not ship": the stopped exit code, and nothing pushed, opened or removed.
        guard case .exited(let code)? = exit?.termination else { throw Failed("ship did not exit: \(String(describing: exit))") }
        #expect(code == 3, "ship exits 3 (stopped) after a stop: \(lines)")
        #expect(
            try fx.events(id).allSatisfy { $0.kind != .prOpened && $0.kind != .worktreeRemoved },
            "no pull request was opened and the worktree was kept")
        if !refresh {
            let heads = try await shipOut(["ls-remote", "--heads", "origin"], fx.repo, fx)
            #expect(!heads.contains("workbench/\(id)"), "nothing was pushed: \(heads)")
        }

        let kind: EventKind = refresh ? .prRefreshed : .prDescribed
        let recorded = try #require(try fx.events(id).last { $0.kind == kind })
        #expect(recorded.data["ok"] == false && recorded.data["provider"]?.stringValue == "\(provider)")
        #expect(recorded.data["reason"]?.stringValue?.contains("stopped") == true, "\(recorded.data)")
        #expect(!FileManager.default.fileExists(atPath: fx.project.runnerURL(id).path), "the hold is gone afterwards")
        #expect(fx.service.runnerPID(id: id) == nil)
        #expect(try fx.contents(id).isHealthy)
    }

    @Test(arguments: [AgentProviderID.claude, .codex])
    func stopReachesTheDescriptionTurn(provider: AgentProviderID) async throws {
        try await stopThroughTheHolder(refresh: false, provider: provider)
    }

    @Test(arguments: [AgentProviderID.claude, .codex])
    func stopReachesTheRefreshTurn(provider: AgentProviderID) async throws {
        try await stopThroughTheHolder(refresh: true, provider: provider)
    }
}

@Suite(.processGate) struct ShipShowsCodexTextTests {
    @Test func aCodexDescriptionIsPrintedInFullBeforeThePushUnderYes() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        _ = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        let codex = try FakeCodex(in: fx)
        try codex.put("answer", goodDescription)
        try onCodex(fx, codex, role: "ship")

        let shipped = try await CLI(fx: fx, gh: gh, codex: codex).run(["ship", "--yes"])
        #expect(shipped.code == 0, "\(shipped.text)")
        let title = try #require(shipped.lines.firstIndex { $0 == "title:   feat(a): add hello" }, "\(shipped.text)")
        let body = try #require(shipped.lines.firstIndex { $0.contains("Adds a greeting.") }, "\(shipped.text)")
        let pushed = try #require(shipped.lines.firstIndex { $0.hasPrefix("pushed ") }, "\(shipped.text)")
        #expect(title < pushed && body < pushed)
    }

    @Test(arguments: [AgentProviderID.claude, .codex])
    func aRefreshShowsTheWholeTextOnlyOnCodex(provider: AgentProviderID) async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        _ = try await updateThread(fx, gh)
        var cli = CLI(fx: fx, gh: gh)
        if provider == .codex {
            let codex = try FakeCodex(in: fx)
            try codex.put("answer", fourCountries)
            try onCodex(fx, codex, role: "ship")
            cli.codex = codex
        } else {
            cli.fakeClaude = "answer=\(try scratchFile(fx, "answer", fourCountries).path)"
        }

        let shipped = try await cli.run(["ship", "--yes"])
        #expect(shipped.code == 0, "\(shipped.text)")
        #expect(shipped.text.contains("+ Moves four countries to their latest version."), "\(shipped.text)")
        let pushed = try #require(shipped.lines.firstIndex { $0.hasPrefix("pushed ") }, "\(shipped.text)")
        let whole = shipped.lines.firstIndex { $0.contains(untouched) }
        let title = shipped.lines.firstIndex { $0 == "title:   chore: bump four countries" }
        if provider == .codex {
            #expect(whole.map { $0 < pushed } == true && title.map { $0 < pushed } == true, "\(shipped.text)")
        } else {
            #expect(whole == nil && title == nil, "on Claude only the change is shown, as before: \(shipped.text)")
        }
    }
}

@Suite(.processGate) struct PlanBoundOutputTests {
    @Test func onClaudeItPrintsTheDollarCap() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let out = try await CLI(fx: fx, fakeClaude: "exit=1").run(["plan", "--budget", "0.75"])
        #expect(out.text.contains("planning \(id) (read-only; up to $0.75)..."), "\(out.text)")
    }

    @Test func onCodexItSaysThereIsNoDollarCapAndWhatBoundsIt() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let codex = try FakeCodex(in: fx)
        try codex.put("crash", "")
        try onCodex(fx, codex, role: "plan")
        let out = try await CLI(fx: fx, codex: codex).run(["plan"])
        let line = try #require(out.lines.first { $0.hasPrefix("planning \(id)") }, "\(out.text)")
        #expect(!line.contains("$") && line.contains("no dollar cap"), "\(line)")
        #expect(line.contains("\(Int(Plan.timeout / 60)) min"), "\(line)")
    }

    @Test func budgetOnCodexIsAUsageError() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let codex = try FakeCodex(in: fx)
        try onCodex(fx, codex, role: "plan")
        let out = try await CLI(fx: fx, codex: codex).run(["plan", "--budget", "1"])
        #expect(out.code == 2, "\(out.text)")
        #expect(out.text.contains("--budget") && out.text.contains("codex"), "\(out.text)")
        #expect(codex.runs == 0)
        #expect(try fx.events(id).allSatisfy { $0.kind != .planStarted && $0.kind != .planEnded }, "nothing was recorded")
    }
}
