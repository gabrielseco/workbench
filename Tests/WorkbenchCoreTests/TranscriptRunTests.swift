import Foundation
import Testing

@testable import WorkbenchCore

/// The transcript through a real runner and the fake claude, whichever way the turn ends.
@Suite(.processGate) struct TranscriptRunTests {
    @Test(arguments: [
        (["exit=2"], 1.0),
        (["crash-after=1"], 1.0),
        (["die-after=2"], 1.0),
        (["partial-tail"], 1.0),
        (["hang-after=1"], 0.6),
    ])
    func turnEndedSaysWhatTheFileHoldsWhateverHappened(directives: [String], timeout: Double) async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        var options = fx.options(timeout: timeout)
        options.parentEnvironment["FAKE_CLAUDE"] = directives.joined(separator: ",")

        _ = try await fx.runner(id).run(options)

        let contents = try fx.contents(id)
        #expect(contents.isHealthy && contents.openTurn == nil)
        let end = try #require(contents.events.last { $0.kind == .turnEnded })
        let file = TranscriptFile.summary(at: TranscriptFile.url(in: fx.project.threadDirectory(id), turn: 1))
        #expect(end.data["transcript"] == file?.json, "\(directives): \(String(describing: end.data["transcript"]))")
        // Whatever the child printed before it ended is in the file, as whole lines.
        #expect(file.map { $0.lines > 0 } ?? false, "\(directives)")
        #expect(fx.transcript(id).count == file?.lines)
    }

    @Test func aTurnThatNeverStartedAProcessHasNoTranscriptAndNoField() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let runner = fx.runner(id)
        await runner.stop()
        let report = try await runner.run(fx.options())
        #expect(report.result == .stopped)
        let end = try #require(try fx.events(id).last { $0.kind == .turnEnded })
        #expect(end.data["transcript"] == nil)
        #expect(fx.transcript(id).isEmpty)
    }
}
