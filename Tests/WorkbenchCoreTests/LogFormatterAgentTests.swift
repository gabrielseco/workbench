import Testing

@testable import WorkbenchCore

@Suite struct LogFormatterAgentTests {
    private func line(_ kind: EventKind, _ data: JSONValue) -> String {
        LogFormatter.describe(Event(seq: 7, ts: "2026-10-24T10:00:00.000Z", turn: 1, kind: kind, data: data))
    }

    @Test func anAttemptIsOneLineEachWayWithTheProviderAndModel() {
        let started = line(
            .agentAttemptStarted,
            ["attempt": "a5", "role": "review", "stage": "design", "round": 2, "provider": "codex", "model": .null])
        #expect(started.hasSuffix("attempt a5: review design round 2 on codex, default model"), "\(started)")
        #expect(line(.agentAttemptStarted, ["attempt": "a6", "role": "judge", "provider": "claude", "model": "haiku"])
            .hasSuffix("attempt a6: judge on claude, haiku"))
        #expect(line(.agentAttemptStarted, ["attempt": "a7", "role": "judge", "provider": "claude", "spawned": false])
            .hasSuffix(", nothing started"))
    }

    @Test func anEndSaysHowItEndedAndWhetherRecoveryWroteIt() {
        #expect(line(.agentAttemptEnded, ["attempt": "a5", "outcome": "succeeded"]).hasSuffix("attempt a5 ended: succeeded"))
        let recovered = line(.agentAttemptEnded, ["attempt": "a5", "outcome": "interrupted", "synthetic": true])
        #expect(recovered.hasSuffix("attempt a5 ended: interrupted (recovered)"), "\(recovered)")
        #expect(line(.agentAttemptEnded, ["attempt": "a5", "outcome": "refused", "reason": "`codex` was not found"])
            .contains("refused (`codex` was not found)"))
    }

    @Test func aDraftIsOneLineEachWay() {
        let started = line(.goalDraftStarted, ["provider": "codex", "model": .null])
        #expect(started.hasSuffix("goal draft started on codex, default model"))
        let failed = line(.goalDraftFinished, ["ok": false, "reason": "interrupted"])
        #expect(failed.hasSuffix("goal draft did not finish (interrupted)"))
        #expect(line(.goalDraftFinished, ["ok": true]).hasSuffix("goal draft finished"))
    }

    @Test func controlCharactersInAReasonAreNotPrinted() {
        let text = line(.agentAttemptEnded, ["attempt": "a1", "outcome": "failed", "reason": "bad\u{1B}[31m\nred"])
        #expect(!text.contains("\u{1B}") && !text.contains("\n"), "\(text)")
    }
}
