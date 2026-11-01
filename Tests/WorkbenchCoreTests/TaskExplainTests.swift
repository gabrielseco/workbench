import Foundation
import Testing

@testable import WorkbenchCore

struct TaskExplanationTests {
    @Test func textFromOutsideIsOneLineWithoutControlCharacters() {
        let hostile = "line one\nline two\u{1B}[31m red \u{0}nul\u{7}bell\r\n\ttab   spaces"
        let cleaned = TaskExplanation.clean(hostile, limit: 500)
        for bad in ["\n", "\u{1B}", "\u{0}", "\u{7}"] { #expect(!cleaned.contains(bad)) }
        #expect(cleaned == "line one line two [31m red nul bell tab spaces")
    }

    @Test func everyPartIsBounded() {
        let long = String(repeating: "x", count: 5_000)
        let explanation = TaskExplanation(
            message: long, denied: (0..<9).map { _ in long }, checkTail: (0..<40).map { "line \($0) " + long })
        #expect(explanation.message?.count == TaskExplanation.maxMessage && explanation.message?.hasSuffix("…") == true)
        #expect(explanation.denied.count == TaskExplanation.maxDenied)
        #expect(explanation.denied.allSatisfy { $0.count == TaskExplanation.maxCommand })
        #expect(explanation.checkTail.count == TaskExplanation.maxCheckLines)
        #expect(explanation.checkTail.allSatisfy { $0.count <= TaskExplanation.maxCheckLine })
        #expect(explanation.reason("stopped", includeCheck: true).count <= TaskExplanation.maxReason)
    }

    @Test func theCheckKeepsItsLastLinesAndOnlyWhenAsked() {
        let explanation = TaskExplanation(checkTail: (1...20).map { "noise \($0)" })
        #expect(explanation.checkTail == (13...20).map { "noise \($0)" })
        #expect(!explanation.reason("the check failed").contains("noise"))
        #expect(explanation.reason("the check failed", includeCheck: true).contains("noise 20"))
    }

    @Test func nothingToSayAddsNothing() {
        #expect(TaskExplanation(message: "  \n ").reason("stopped") == "stopped")
        #expect(TaskExplanation().reason("stopped", includeCheck: true) == "stopped")
    }
}

/// A task in a project with a real repository and the fake claude, to see what a run that stops says.
private struct Env {
    let fx: RunnerFixture
    let task: TaskFixture

    init(extraConfig: String = #"check_command = "true""#) async throws {
        fx = try await RunnerFixture(extraConfig: extraConfig)
        task = try TaskFixture(in: fx.project, front: "fix: pr")
        try await task.library.approve(task.name)
    }

    func run(_ directives: String...) async -> TaskRunResult { await run(task.name, directives) }

    func run(_ name: String, _ directives: [String]) async -> TaskRunResult {
        var runner = TaskRunner(project: fx.project, git: fx.git, gh: nil)
        runner.runOptions = fx.options(directives.joined(separator: ","))
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        return await runner.run(name, trigger: .manual)
    }
}

@Suite(.processGate) struct TaskExplainTests {
    @Test func aRunThatChangedNothingSaysWhatTheAgentSaid() async throws {
        let env = try await Env()
        let result = await env.run()
        #expect(result.outcome == .nothingToDo)
        let reason = try #require(result.reason)
        #expect(reason.hasPrefix("the agent changed nothing, so there is nothing to ship; the agent said: fake claude:"))
        #expect(reason.count <= TaskExplanation.maxReason && !reason.contains("\n"))
    }

    @Test func aTurnThatEndedWithoutAResultStillSaysWhatTheAgentSaid() async throws {
        let env = try await Env()
        // The stream has the agent's text but no terminal result, as a crash or a timeout leaves it.
        let result = await env.run("no-result")
        #expect(result.outcome != .prOpened && result.thread != nil)
        #expect(result.reason?.contains("the agent said: fake claude:") == true, "\(result.outcome) \(result.reason ?? "")")
    }

    @Test func aFailureAfterTheTurnKeepsTheExplanation() async throws {
        let env = try await Env()
        // The work is done and the check passes; there is no origin, so the ship step fails after the agent's turn.
        let result = await env.run("write=a.txt", "deny=pnpm run schema-snapshot")
        #expect(result.outcome == .failed)
        let reason = try #require(result.reason)
        #expect(reason.contains("not shipped") && reason.contains("the agent said: fake claude:"))
        #expect(reason.contains("denied: pnpm run schema-snapshot"))
    }

    @Test func aReasonFromAnyPathIsOneCleanLine() async throws {
        let env = try await Env()
        let noisy = try TaskFixture(in: env.fx.project, name: "noisy", front: "fix: report\npending: noisy.sh")
        try noisy.script("printf 'boom\\033[31m red\\nsecond line\\n' >&2; exit 3", as: "noisy.sh")
        try await noisy.library.approve("noisy")
        let result = await env.run("noisy", [])
        #expect(result.outcome == .failed)
        let reason = try #require(result.reason)
        #expect(reason.contains("exited with 3") && reason.contains("boom"))
        #expect(!reason.contains("\u{1B}") && !reason.contains("\n") && reason.count <= TaskExplanation.maxReason)
        let recorded = try #require(
            try EventLogReader.read(at: noisy.log.url).events.last { $0.kind == .taskRunEnded }?.data["reason"]?.stringValue)
        #expect(recorded == reason)
    }

    @Test func theCommandsTheTurnWasDeniedAreInTheReason() async throws {
        let env = try await Env()
        let result = await env.run("deny=pnpm run dump:schema --country=AUS")
        #expect(result.outcome == .nothingToDo)
        #expect(result.reason?.contains("denied: pnpm run dump:schema --country=AUS") == true)
    }

    @Test func aFailedCheckShowsTheEndOfItsOutputAndOnlyThat() async throws {
        let script = Scratch.url("check", ext: "sh")
        let lines = (1...20).map { "echo noise-\($0)" } + ["echo 'FAIL: expected 3, got 4'", "exit 1"]
        try (["#!/bin/sh"] + lines).joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let env = try await Env(extraConfig: "check_command = \"\(script.path)\"")
        let result = await env.run("write=a.txt")
        #expect(result.outcome == .failed)
        let reason = try #require(result.reason)
        #expect(reason.contains("the check failed") && reason.contains("check output: "))
        #expect(reason.contains("FAIL: expected 3, got 4") && reason.contains("noise-14"))
        #expect(!reason.contains("noise-13 "))
        #expect(reason.count <= TaskExplanation.maxReason)
    }
}

@Suite(.processGate) struct TaskLogTests {
    private func report(_ env: Env) throws -> [String] {
        try TaskLogReport.lines(project: env.fx.project, name: env.task.name, timeZone: TimeZone(identifier: "UTC") ?? .gmt)
    }

    @Test func aTaskThatNeverRanSaysSo() throws {
        let fx = try TaskFixture()
        #expect(try TaskLogReport.lines(project: fx.project, name: fx.name) == ["bump has never run."])
    }

    @Test func theLastRunIsToldWithItsThreadsSetupCheckAndLastMessage() async throws {
        let env = try await Env(extraConfig: "check_command = \"false\"\nsetup_command = \"true\"")
        let result = await env.run("write=a.txt")
        let lines = try report(env)
        #expect(lines.first == "bump  run 1 of 1")
        #expect(lines.contains("outcome:  failed"))
        #expect(lines.contains { $0.hasPrefix("reason:   the check failed") })
        #expect(lines.contains("thread:   \(try #require(result.thread))"))
        #expect(lines.contains { $0.hasPrefix("setup:    passed") })
        #expect(lines.contains { $0.hasPrefix("check:    failed") })
        #expect(lines.contains { $0.hasPrefix("agent:    fake claude:") })
        #expect(lines.contains { $0.hasPrefix("started:  ") && $0.hasSuffix("(manual)") })
    }

    @Test func aStoredReasonIsCleanedOnTheWayOut() async throws {
        let fx = try TaskFixture()
        let writer = try await fx.log.openWriter()
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(
            .taskRunEnded,
            data: [
                "outcome": "failed",
                "reason": .string("boom\u{1B}[31m red\nsecond line " + String(repeating: "x", count: 5_000)),
            ])
        await writer.close()
        let line = try #require(try TaskLogReport.lines(project: fx.project, name: fx.name).first { $0.hasPrefix("reason:") })
        #expect(!line.contains("\u{1B}") && !line.contains("\n") && line.count <= TaskExplanation.maxReason + 20)
    }

    @Test func denialsAreCountedFromTheTurnsOwnRecord() async throws {
        let project = Project(root: try Scratch.directory("denials"))
        let log = try EventLogWriter.open(at: project.eventsURL("g-x"))
        let call: JSONValue = .object(["tool_name": .string("Bash"), "tool_input": .object(["command": .string("pnpm run x")])])
        try await log.append(.turnStarted, turn: 1, data: ["pid": 1])
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded", "denials": .array([call, call])])
        await log.close()
        // The stream had no denial events; the turn's own record has two.
        let lines = TaskLogReport.threadLines(project: project, thread: "g-x")
        #expect(lines.contains { $0.hasPrefix("denied:   2 tool call(s)") }, "\(lines)")
    }

    @Test func aRunWhoseThreadWasRemovedSaysSoInsteadOfFailing() async throws {
        let fx = try TaskFixture()
        let writer = try await fx.log.openWriter()
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(
            .taskRunEnded,
            data: ["outcome": "pr-opened", "units": ["ROU"], "thread": "g-gone", "pr": "https://github.com/o/r/pull/9"])
        await writer.close()
        let lines = try TaskLogReport.lines(project: fx.project, name: fx.name)
        #expect(lines.contains("pull request: https://github.com/o/r/pull/9"))
        #expect(lines.contains("thread log: not found (the thread was removed)"))
    }

    @Test func allListsEveryRunInOneLineEach() async throws {
        let fx = try TaskFixture()
        let writer = try await fx.log.openWriter(now: { Date(timeIntervalSince1970: 1_793_000_000) })
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(.taskRunEnded, data: ["outcome": "pr-opened", "units": ["NZL", "ALB"]])
        try await writer.append(.taskRunStarted, data: ["trigger": "manual"])
        try await writer.append(
            .taskRunEnded, data: ["outcome": "nothing-to-do", "reason": "the agent changed nothing\nsecond line"])
        await writer.close()
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let lines = try TaskLogReport.lines(project: fx.project, name: fx.name, all: true, timeZone: utc)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("tick  pr-opened  NZL,ALB"))
        #expect(lines[1].contains("manual  nothing-to-do  the agent changed nothing second line"))
    }
}
