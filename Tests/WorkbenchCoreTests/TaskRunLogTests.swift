import Foundation
import Testing

@testable import WorkbenchCore

struct TaskRunLogTests {
    @Test func anAbsentLogIsAnEmptyHistory() throws {
        let history = try TaskFixture().log.history()
        #expect(history.runs.isEmpty && history.approvedHash == nil && history.scheduleBase == nil)
    }

    @Test func theHistoryIsDerivedFromTheEvents() async throws {
        let fx = try TaskFixture()
        let writer = try await fx.log.openWriter()
        try await writer.append(.taskApproved, data: ["hash": "abc"])
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(
            .taskRunEnded, data: ["outcome": "pr-opened", "units": ["ROU", "TUR"], "thread": "g-1-bump"])
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(.taskRunEnded, data: ["outcome": "nothing-pending", "units": []])
        await writer.close()

        let history = try fx.log.history()
        #expect(history.approvedHash == "abc" && history.runs.count == 2)
        #expect(history.runs[0].outcome == .prOpened && history.runs[0].thread == "g-1-bump")
        #expect(history.unitsWithThreads == ["ROU": "g-1-bump", "TUR": "g-1-bump"])
        #expect(history.lastRun?.outcome == .nothingPending && history.openRun == nil)
    }

    @Test func seqHasNoGaps() async throws {
        let fx = try TaskFixture()
        let writer = try await fx.log.openWriter()
        for _ in 0..<3 { try await writer.append(.taskApproved, data: ["hash": "h"]) }
        await writer.close()
        let events = try EventLogReader.read(at: fx.log.url).events
        #expect(events.map(\.seq) == [1, 2, 3])
    }

    @Test func aRunThatNeverWroteItsEndIsClosedByTheNextWriter() async throws {
        let fx = try TaskFixture()
        let first = try await fx.log.openWriter()
        try await first.append(.taskRunStarted, data: ["trigger": "tick"])
        await first.close()
        #expect(try fx.log.history().openRun != nil)

        let second = try await fx.log.openWriter()
        await second.close()
        let history = try fx.log.history()
        #expect(history.openRun == nil && history.runs.count == 1)
        #expect(history.runs[0].outcome == .interrupted)
    }

    @Test func aSecondWriterIsRefusedWhileTheFirstIsOpen() async throws {
        let fx = try TaskFixture()
        let first = try await fx.log.openWriter()
        await #expect(throws: EventLogError.self) { _ = try await fx.log.openWriter() }
        await first.close()
        _ = try await fx.log.openWriter().close()
    }

    @Test func aDamagedLogIsNotAppendedTo() async throws {
        let fx = try TaskFixture()
        try FileManager.default.createDirectory(at: fx.project.taskDirectory(fx.name), withIntermediateDirectories: true)
        try "{\"v\":1,\"seq\":7,\"ts\":\"2026-01-01T00:00:00.000Z\",\"turn\":0,\"kind\":\"task.approved\",\"data\":{}}\n"
            .write(to: fx.log.url, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { _ = try await fx.log.openWriter() }
        #expect(throws: (any Error).self) { _ = try fx.log.history() }
    }
}
