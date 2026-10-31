import Foundation
import Testing

@testable import WorkbenchCore

struct TaskScheduleTests {
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

    private let weekdaysAtFour = TaskSchedule.daily(at: TimeOfDay(hour: 4, minute: 0), days: Set(2...6))

    @Test func theNextSlotIsTheNextWeekdayAtTheTime() {
        #expect(weekdaysAtFour.nextDue(since: date(2, 9), calendar: Self.utc) == date(3, 4))
        #expect(weekdaysAtFour.nextDue(since: date(2, 3), calendar: Self.utc) == date(2, 4))
    }

    @Test func fridayEveningWaitsForMonday() {
        #expect(weekdaysAtFour.nextDue(since: date(6, 20), calendar: Self.utc) == date(9, 4))
    }

    @Test func aTaskIsDueOnlyOnceTheSlotHasPassed() {
        #expect(!weekdaysAtFour.isDue(since: date(2, 9), now: date(3, 3, 59), calendar: Self.utc))
        #expect(weekdaysAtFour.isDue(since: date(2, 9), now: date(3, 4), calendar: Self.utc))
    }

    @Test func aMachineThatWasOffForDaysRunsOnceNotOncePerMissedSlot() {
        let lastRun = date(2, 4)
        let now = date(6, 12)
        #expect(weekdaysAtFour.isDue(since: lastRun, now: now, calendar: Self.utc))
        // The catch-up run starts at `now`; the next slot is counted from there, so nothing else is owed.
        #expect(!weekdaysAtFour.isDue(since: now, now: now, calendar: Self.utc))
        #expect(weekdaysAtFour.nextDue(since: now, calendar: Self.utc) == date(9, 4))
    }

    @Test func anIntervalCountsFromTheLastRun() {
        let hourly = TaskSchedule.every(seconds: 3600)
        #expect(hourly.nextDue(since: date(2, 9)) == date(2, 10))
        #expect(!hourly.isDue(since: date(2, 9), now: date(2, 9, 59)))
        #expect(hourly.isDue(since: date(2, 9), now: date(2, 10)))
    }

    @Test func aDaySetWithNoDaysIsNeverDue() {
        let never = TaskSchedule.daily(at: TimeOfDay(hour: 4, minute: 0), days: [])
        #expect(never.nextDue(since: date(2, 9), calendar: Self.utc) == nil)
    }

    @Test func theSummaryReadsBackWhatWasSet() throws {
        #expect(weekdaysAtFour.summary == "weekdays 04:00")
        #expect(TaskSchedule.every(seconds: 3600).summary == "every 1h")
        #expect(TaskSchedule.every(seconds: 1800).summary == "every 30m")
        let mixed = TaskSchedule.daily(at: TimeOfDay(hour: 9, minute: 30), days: [2, 4])
        #expect(mixed.summary == "mon,wed 09:30")
    }
}
