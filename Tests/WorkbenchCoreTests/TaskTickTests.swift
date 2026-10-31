import Foundation
import Testing

@testable import WorkbenchCore

struct TaskTickTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// 2026-11-02 is a Monday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let parts = DateComponents(
            calendar: Self.utc, timeZone: Self.utc.timeZone, year: 2026, month: 11, day: day, hour: hour, minute: minute)
        return Self.utc.date(from: parts) ?? .distantPast
    }

    private func due(_ fx: TaskFixture, at now: Date) -> [String] {
        TaskTick.due(project: fx.project, now: now, calendar: Self.utc)
    }

    @Test func aTaskIsDueOnceItsSlotAfterApprovalHasPassed() async throws {
        let fx = try TaskFixture(front: "at: 04:00\ndays: weekdays\nfix: report")
        try await fx.library.approve(fx.name, now: { date(2, 9) })
        #expect(due(fx, at: date(3, 3, 59)).isEmpty)
        #expect(due(fx, at: date(3, 4)) == ["bump"])
    }

    @Test func aTaskNobodyApprovedNeverFires() throws {
        let fx = try TaskFixture(front: "at: 04:00\nfix: report")
        #expect(due(fx, at: date(9, 12)).isEmpty)
    }

    @Test func aTaskWithNoScheduleIsNeverDue() async throws {
        let fx = try TaskFixture(front: "fix: report")
        try await fx.library.approve(fx.name, now: { date(2, 9) })
        #expect(due(fx, at: date(30, 12)).isEmpty)
    }

    @Test func aStaleTaskIsStillDueSoTheRunCanSayWhyItDidNotRun() async throws {
        let fx = try TaskFixture(front: "at: 04:00\nfix: report")
        try await fx.library.approve(fx.name, now: { date(2, 9) })
        try fx.write(task: "---\nat: 04:00\nfix: report\n---\nChanged.\n")
        #expect(due(fx, at: date(3, 5)) == ["bump"])
    }

    @Test func aMachineThatWasOffForDaysOwesOneRun() async throws {
        let fx = try TaskFixture(front: "at: 04:00\nfix: report")
        try await fx.library.approve(fx.name, now: { date(2, 9) })
        #expect(due(fx, at: date(6, 12)) == ["bump"])
        // The run that catches up starts at `now`; the slots it missed are not owed.
        let writer = try await fx.log.openWriter(now: { date(6, 12) })
        try await writer.append(.taskRunStarted, data: ["trigger": "tick"])
        try await writer.append(.taskRunEnded, data: ["outcome": "reported", "units": []])
        await writer.close()
        #expect(due(fx, at: date(6, 13)).isEmpty)
        #expect(due(fx, at: date(7, 5)) == ["bump"])
    }

    @Test func dueTasksComeEarliestFirst() async throws {
        let late = try TaskFixture(name: "late", front: "at: 06:00\nfix: report")
        let early = try TaskFixture(in: late.project, name: "early", front: "at: 03:00\nfix: report")
        for fx in [late, early] { try await fx.library.approve(fx.name, now: { date(2, 9) }) }
        #expect(due(late, at: date(3, 7)) == ["early", "late"])
    }
}
