import Foundation
import Testing

@testable import WorkbenchCore

/// `[verifier] auto = true`: the turn runner starts the verifier after a passing check.
@Suite struct VerifierAutoTests {
    private func kinds(_ v: VerifierFixture) throws -> [String] { try v.fx.kinds(v.id) }

    private func verifierKinds(_ v: VerifierFixture) throws -> [String] {
        try kinds(v).filter { $0.hasPrefix("verifier.") }
    }

    @Test func itRunsAfterAPassingCheckAndTheTurnReportsIt() async throws {
        let v = try await VerifierFixture(verifier: "auto = true", check: "true", runTurn: false)
        let notices = NoticeBox()
        let report = try await v.fx.runner(v.id, notices: notices).run(v.fx.options("write=a.txt,proof=shot.png"))

        #expect(report.result == .succeeded && report.check?.result == .passed)
        let verifier = try #require(report.verifier)
        #expect(verifier.ok && verifier.turn == 1 && verifier.files.map(\.name) == ["shot.png"])
        let order = try kinds(v).filter { ["turn.ended", "check.ran", "verifier.started", "verifier.ended"].contains($0) }
        #expect(order == ["turn.ended", "check.ran", "verifier.started", "verifier.ended"], "\(order)")
        #expect(try v.fx.contents(v.id).isHealthy)
        let seen = notices.all.compactMap { notice -> String? in
            switch notice {
            case .verifierStarted(_, let skill): "started \(skill)"
            case .verifierEnded(let ended): "ended \(ended.ok)"
            default: nil
            }
        }
        #expect(seen == ["started \(".claude/skills/verify/SKILL.md")", "ended true"])
    }

    @Test func itDoesNotRunUnlessSwitchedOn() async throws {
        let v = try await VerifierFixture(verifier: "", check: "true", runTurn: false)
        let report = try await v.fx.runner(v.id).run(v.fx.options("write=a.txt"))
        #expect(report.verifier == nil)
        #expect(try verifierKinds(v).isEmpty)
    }

    @Test func itDoesNotRunAfterAFailedCheck() async throws {
        let v = try await VerifierFixture(verifier: "auto = true", check: "false", runTurn: false)
        let report = try await v.fx.runner(v.id).run(v.fx.options("write=a.txt"))
        #expect(report.check?.result == .failed && report.verifier == nil)
        #expect(try verifierKinds(v).isEmpty)
    }

    @Test func itRunsWhenTheProjectHasNoCheck() async throws {
        let v = try await VerifierFixture(verifier: "auto = true", runTurn: false)
        let report = try await v.fx.runner(v.id).run(v.fx.options("write=a.txt"))
        #expect(report.check == nil && report.verifier?.ok == true)
        #expect(try verifierKinds(v) == ["verifier.started", "verifier.ended"])
    }

    private func skipReason(_ v: VerifierFixture) throws -> String? {
        try v.fx.events(v.id).last { $0.kind == .verifierSkipped }?.data["reason"]?.stringValue
    }

    @Test func itDoesNotRunWhenTheTurnLeftNothingToLookAtAndSaysSo() async throws {
        let v = try await VerifierFixture(verifier: "auto = true", check: "true", runTurn: false)
        let notices = NoticeBox()
        let report = try await v.fx.runner(v.id, notices: notices).run(v.fx.options())
        #expect(report.result == .succeeded && report.verifier == nil)
        #expect(try verifierKinds(v) == ["verifier.skipped"])
        #expect(try skipReason(v) == "the turn left no change to look at")
        #expect(notices.all.contains { if case .advisory(let t) = $0 { t.contains("no change to look at") } else { false } })
        #expect(try v.fx.contents(v.id).isHealthy)
    }

    @Test func itDoesNotRunAfterATurnThatFailed() async throws {
        let v = try await VerifierFixture(verifier: "auto = true", check: "true", runTurn: false)
        let report = try await v.fx.runner(v.id).run(v.fx.options("write=a.txt,exit=1"))
        #expect(report.result != .succeeded && report.verifier == nil)
        #expect(try verifierKinds(v).isEmpty)
    }

    @Test func itDoesNotRunWhenThisTurnAlreadyHasAnEndedVerifier() async throws {
        let v = try await VerifierFixture(verifier: "auto = true", runTurn: false)
        let log = try EventLogWriter.open(at: v.fx.project.eventsURL(v.id))
        try await log.append(.verifierStarted, turn: 1, data: ["argv": ["claude"]])
        try await log.append(.verifierEnded, turn: 1, data: ["ok": true])
        await log.close()
        let report = try await v.fx.runner(v.id).run(v.fx.options("write=a.txt"))
        #expect(report.verifier == nil)
        #expect(
            try verifierKinds(v) == ["verifier.started", "verifier.ended", "verifier.skipped"],
            "the one that was already there, and the skip")
        #expect(try skipReason(v) == "a verifier has ended for this turn already")
    }

    @Test func aSkillMissingAtTheBaseIsANoteAndTheTurnStillSucceeds() async throws {
        let v = try await VerifierFixture(verifier: "auto = true", skill: nil, runTurn: false)
        let notices = NoticeBox()
        let report = try await v.fx.runner(v.id, notices: notices).run(v.fx.options("write=a.txt"))
        #expect(report.result == .succeeded && report.verifier == nil)
        #expect(try verifierKinds(v) == ["verifier.skipped"])
        #expect(try skipReason(v)?.contains(".claude/skills/verify/SKILL.md") == true)
        let notes = notices.all.compactMap { notice -> String? in
            if case .advisory(let text) = notice { text } else { nil }
        }
        let named = notes.contains { $0.contains("the verifier did not run") && $0.contains(".claude/skills/verify/SKILL.md") }
        #expect(named, "\(notes)")
    }

    @Test func aVerifierThatFailsDoesNotFailTheTurn() async throws {
        let v = try await VerifierFixture(verifier: "auto = true", check: "true", runTurn: false)
        // `budget-stop` only changes the json answer; the coding turn is a stream and ignores it.
        let report = try await v.fx.runner(v.id).run(v.fx.options("write=a.txt,budget-stop"))
        #expect(report.result == .succeeded)
        #expect(report.verifier?.ok == false && report.verifier?.reason?.contains("budget") == true)
        #expect(try verifierKinds(v) == ["verifier.started", "verifier.ended"])
    }

    @Test func theTimeoutIsTheConfiguredOneAndTheTurnStillEnds() async throws {
        let v = try await VerifierFixture(verifier: "auto = true\ntimeout_min = 1", runTurn: false)
        var options = v.fx.options("write=a.txt")
        options.verifierTimeoutOverride = 1
        options.parentEnvironment["FAKE_CLAUDE"] = "write=a.txt,hang-after=99"
        // hang-after only hangs the json answer when it is set; 99 lines never come in a stream, so the turn is fine.
        let report = try await v.fx.runner(v.id).run(options)
        #expect(report.verifier?.ok == false && report.verifier?.reason?.contains("did not finish within 1s") == true)
        #expect(try verifierKinds(v) == ["verifier.started", "verifier.ended"])
    }
}
