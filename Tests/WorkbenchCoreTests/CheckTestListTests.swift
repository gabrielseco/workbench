import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct CheckTestListTests {
    @Test func theTestsTheOutputShowedAreRecordedOnTheEvent() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(
            try script.write(
                "echo '✔ Test a() passed after 0.001 seconds.'\necho '✘ Test b() failed after 0.001 seconds.'\nexit 1"))
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let ran = try #require(try fx.checkRuns(id).first)
        #expect(ran.data["tests_passed"] == ["a()"])
        #expect(ran.data["tests_failed"] == ["b()"])
        let state = ThreadState.derive(from: try fx.events(id), id: id)
        #expect(state.review.check?.tests == CheckTests(passed: ["a()"], failed: ["b()"]))
    }

    @Test func aCheckWithNoKnownTestOutputRecordsNoLists() async throws {
        let script = try CheckScript()
        let fx = try await RunnerFixture.checking(try script.write("echo ok"))
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let ran = try #require(try fx.checkRuns(id).first)
        #expect(ran.data["tests_passed"] == nil)
        let state = ThreadState.derive(from: try fx.events(id), id: id)
        #expect(state.review.check?.tests == nil)
    }
}
