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

    // Monthly: the first tick on or after a day of the month.
    private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 6, _ minute: Int = 0) -> Date {
        let parts = DateComponents(
            calendar: Self.utc, timeZone: Self.utc.timeZone, year: year, month: month, day: day, hour: hour, minute: minute)
        return Self.utc.date(from: parts) ?? .distantPast
    }

    private let monthly = TaskSchedule.monthly(at: TimeOfDay(hour: 6, minute: 0), day: 1)

    @Test func monthlyIsDueOnTheFirstAtTheTimeAndThenNextMonth() {
        #expect(monthly.nextDue(since: day(2026, 11, 5), calendar: Self.utc) == day(2026, 12, 1))
        #expect(monthly.nextDue(since: day(2026, 11, 1, 5, 59), calendar: Self.utc) == day(2026, 11, 1))
        let atSlot = monthly.nextDue(since: day(2026, 11, 1, 6, 0), calendar: Self.utc)
        #expect(atSlot == day(2026, 12, 1), "a run at the slot is not owed again")
        #expect(monthly.nextDue(since: day(2026, 12, 31, 23, 0), calendar: Self.utc) == day(2027, 1, 1), "across the year")
    }

    @Test func aDayLateInTheMonthSpansFebruaryWithoutDrifting() {
        let late = TaskSchedule.monthly(at: TimeOfDay(hour: 6, minute: 0), day: 28)
        #expect(late.nextDue(since: day(2027, 1, 28, 7), calendar: Self.utc) == day(2027, 2, 28))
        #expect(late.nextDue(since: day(2027, 2, 28, 7), calendar: Self.utc) == day(2027, 3, 28))
        #expect(late.nextDue(since: day(2028, 2, 20), calendar: Self.utc) == day(2028, 2, 28), "a leap year")
        #expect(monthly.nextDue(since: day(2027, 1, 31, 12), calendar: Self.utc) == day(2027, 2, 1), "from a 31st into February")
        #expect(monthly.nextDue(since: day(2027, 2, 28, 12), calendar: Self.utc) == day(2027, 3, 1), "from the end of February")
    }

    @Test func aMissedMonthRunsOnceOnTheNextTickAndIsNotOwedAgain() {
        let lastRun = day(2026, 11, 1)
        let now = day(2027, 2, 14, 9)
        #expect(monthly.isDue(since: lastRun, now: now, calendar: Self.utc), "December's slot is long past")
        // The catch-up starts at `now`, so January's and February's slots are not owed: the next is March's.
        #expect(!monthly.isDue(since: now, now: now, calendar: Self.utc))
        #expect(monthly.nextDue(since: now, calendar: Self.utc) == day(2027, 3, 1))
    }

    @Test func monthlySummaryNamesTheDayWhenItIsNotTheFirst() {
        #expect(monthly.summary == "monthly 06:00")
        #expect(TaskSchedule.monthly(at: TimeOfDay(hour: 6, minute: 30), day: 15).summary == "monthly on day 15 06:30")
    }
}
