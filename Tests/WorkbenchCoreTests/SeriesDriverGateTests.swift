import Foundation
import Testing

@testable import WorkbenchCore

/// What the driver does with the log a step leaves, beyond the order of its commands (see `SeriesDriverTests`).
@Suite(.processGate) struct SeriesDriverGateTests {
    @Test func aCheckThatFailedAfterASuccessfulRunStopsBeforeAnythingIsAccepted() async throws {
        for result in ["failed", "timed_out", "interrupted"] {
            let rig = try await SeriesRig(seriesTwoSteps)
            _ = try rig.library.approve("s")
            let commands = SeriesFakeCommands()
            commands.checkResult = result
            let out = try await rig.driver(commands, states: SeriesShipped().states).run("s")
            guard case .stopped(1, let reason) = out else {
                Issue.record("expected stopped, got \(out)")
                continue
            }
            #expect(reason.contains("check \(result)") && reason.contains("not accepted"))
            #expect(commands.words == ["goal new", "goal approve", "run --thread"], "\(result)")
            #expect(SeriesStepLog(project: rig.fx.project, series: "s").read()[1]?.stopped == reason)
        }
    }

    @Test func aRunWithNoCheckForItsTurnStopsToo() async throws {
        let rig = try await SeriesRig(seriesTwoSteps)
        _ = try rig.library.approve("s")
        let commands = SeriesFakeCommands()
        commands.checkResult = nil
        let out = try await rig.driver(commands, states: SeriesShipped().states).run("s")
        guard case .stopped(1, let reason) = out else {
            Issue.record("expected stopped, got \(out)")
            return
        }
        #expect(reason.contains("did not run"))
        #expect(!commands.words.contains("accept --thread"))
    }

    @Test func aVerifierThatRanAndFailedStopsBeforeAccept() async throws {
        let rig = try await SeriesRig(seriesTwoSteps)
        _ = try rig.library.approve("s")
        let commands = SeriesFakeCommands()
        commands.verifier = (ok: false, skipped: false)
        let out = try await rig.driver(commands, states: SeriesShipped().states).run("s")
        guard case .stopped(1, let reason) = out else {
            Issue.record("expected stopped, got \(out)")
            return
        }
        #expect(reason.contains("verifier did not pass"))
        #expect(!commands.words.contains("accept --thread"))
    }

    @Test func aProjectWithoutACheckCommandIsNotRunUnattended() async throws {
        let rig = try await SeriesRig(seriesTwoSteps)
        _ = try rig.library.approve("s")
        let config = rig.fx.project.configURL
        let text = try String(contentsOf: config, encoding: .utf8)
        try text.split(separator: "\n").filter { !$0.hasPrefix("check_command") }.joined(separator: "\n")
            .write(to: config, atomically: true, encoding: .utf8)
        let commands = SeriesFakeCommands()
        let out = try await rig.driver(commands) { _ in [:] }.run("s")
        guard case .stopped(1, let reason) = out else {
            Issue.record("expected stopped, got \(out)")
            return
        }
        #expect(reason.contains("no check_command"))
        #expect(commands.calls.isEmpty)
    }

    @Test func aProjectAtItsThreadCapMakesTheSeriesWaitNotStop() async throws {
        let rig = try await SeriesRig(seriesTwoSteps)
        _ = try rig.library.approve("s")
        let commands = SeriesFakeCommands()
        commands.exits["goal new"] = 6
        let out = try await rig.driver(commands) { _ in [:] }.run("s")
        guard case .waiting(1, let reason) = out else {
            Issue.record("expected waiting, got \(out)")
            return
        }
        #expect(reason.contains("`goal new` exited 6"))
    }

    @Test func aFailedGoalNewKeepsTheMarkerSoALateThreadIsFound() async throws {
        let rig = try await SeriesRig(seriesTwoSteps)
        _ = try rig.library.approve("s")
        let commands = SeriesFakeCommands()
        commands.exits["goal new"] = 1
        _ = try await rig.driver(commands) { _ in [:] }.run("s")
        #expect(SeriesStepLog(project: rig.fx.project, series: "s").starting()[1] != nil)
    }

    @Test func ctrlCStartsNothingFurtherAndStopsTheSeries() async throws {
        let rig = try await SeriesRig(seriesTwoSteps)
        _ = try rig.library.approve("s")
        let commands = SeriesFakeCommands()
        commands.stop()
        let out = try await rig.driver(commands) { _ in [:] }.run("s")
        #expect(out == .stopped(step: 1, reason: "stopped by you"))
        #expect(commands.calls.isEmpty)
    }

    @Test func theFollowUpThreadsOfAReviewRoundCountTowardWhatTheSeriesSpent() async throws {
        let rig = try await SeriesRig("---\nbudget_usd: 5.00\n---\n" + seriesTwoSteps)
        _ = try rig.library.approve("s")
        let project = rig.fx.project
        func write(_ thread: String, created: String, cost: Double) throws {
            try FileManager.default.createDirectory(at: project.threadDirectory(thread), withIntermediateDirectories: true)
            let ended = #"{"v":1,"seq":2,"ts":"2026-11-21T10:00:02.000Z","turn":1,"kind":"turn.ended","#
                + #""data":{"result":"succeeded","cost_usd":\#(cost)}}"#
            try (created + "\n" + ended + "\n").write(to: project.eventsURL(thread), atomically: true, encoding: .utf8)
        }
        let root = "g-2026-11-21-s-1"
        let created = #"{"v":1,"seq":1,"ts":"2026-11-21T10:00:00.000Z","turn":0,"kind":"thread.created","data":"#
        try write(root, created: created + "{}}", cost: 0.6)
        try write(
            "g-2026-11-21-s-1-r1", created: created + #"{"parent":"\#(root)","root":"\#(root)","round":1}}"#, cost: 0.5)
        let loaded = try rig.library.load("s")
        let driver = rig.driver(SeriesFakeCommands()) { _ in [:] }
        let spent = driver.spentUSD(loaded, records: [1: SeriesRecord(step: 1, thread: root, at: "t")])
        #expect(abs((spent ?? 0) - 1.1) < 0.0001)
    }

    @Test func aReviewRoundRecordedByAFollowUpReadsAsTheLatestVerdict() {
        let round = PRReviewRecord(
            thread: "g-1-r1", round: 2, pr: 7, ok: true, verdict: .clean, headSHA: "abc", findingsPath: nil)
        let read = SeriesLibrary.review(round)
        #expect(read.verdict == "clean" && read.round == 2 && read.headSHA == "abc" && read.failure == nil)
        let broken = PRReviewRecord(thread: "g-1", round: 1, pr: 7, ok: false, verdict: nil, headSHA: nil, findingsPath: nil)
        #expect(SeriesLibrary.review(broken).verdict == nil && SeriesLibrary.review(broken).failure != nil)
    }
}
