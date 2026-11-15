import Foundation
import Testing

@testable import WorkbenchApp

@MainActor struct WaitWhileTests {
    @Test func returnsAtOnceWhenTheConditionDoesNotHold() async {
        let ended = await wait(while: { false }, atMost: .seconds(30))
        #expect(ended)
    }

    @Test func returnsWhenTheConditionEnds() async {
        var holds = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            holds = false
        }
        let ended = await wait(while: { holds }, atMost: .seconds(30))
        #expect(ended)
        #expect(!holds)
    }

    @Test func givesUpAtTheDeadlineAndSaysSo() async {
        let ended = await wait(while: { true }, atMost: .milliseconds(200))
        #expect(!ended)
    }

    @Test func waitForFailsTheTestAndStopsTheCallerWhenTheConditionNeverHolds() async {
        var wentOn = false
        await withKnownIssue("waitFor reports a timeout as a failure") {
            try await waitFor("a state that never comes", timeout: .milliseconds(100)) { false }
            wentOn = true
        }
        #expect(!wentOn, "the code after a timed-out wait must not run")
    }

    @Test func aDeadlineAlreadyPastChecksOnceAndStops() async {
        let ended = await wait(while: { true }, until: ContinuousClock.now - .seconds(1))
        #expect(!ended)
    }
}
