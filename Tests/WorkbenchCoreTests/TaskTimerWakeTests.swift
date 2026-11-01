import Foundation
import Testing

@testable import WorkbenchCore

struct TaskTimerWakeTests {
    private func task(_ front: String) throws -> TaskDefinition {
        try TaskDefinition.parse("---\n\(front)\n---\nDo it.\n", name: "t")
    }

    @Test func weekdaysAtFourWakeAtFiveToFourOnWeekdays() throws {
        let plan = TimerWake.plan(for: [try task("at: 04:00\ndays: weekdays")])
        #expect(plan == .wake(time: TimeOfDay(hour: 3, minute: 55), days: Set(2...6)))
        #expect(plan.pmsetSchedule == "MTWRF 03:55:00")
        #expect(plan.command == "sudo pmset repeat wakeorpoweron MTWRF 03:55:00")
    }

    @Test func severalTasksWakeAtTheEarliestOnTheUnionOfTheirDays() throws {
        let plan = TimerWake.plan(for: [
            try task("at: 06:30\ndays: mon,wed"), try task("at: 04:10\ndays: tue"), try task("at: 09:00\ndays: sat"),
        ])
        #expect(plan == .wake(time: TimeOfDay(hour: 4, minute: 5), days: [2, 3, 4, 7]))
        #expect(plan.pmsetSchedule == "MTWS 04:05:00")
    }

    @Test func aTimeJustAfterMidnightWakesTheEveningBefore() throws {
        let plan = TimerWake.plan(for: [try task("at: 00:02\ndays: weekdays")])
        #expect(plan == .wake(time: TimeOfDay(hour: 23, minute: 57), days: [1, 2, 3, 4, 5]))
        #expect(plan.pmsetSchedule == "MTWRU 23:57:00")
        let monday = TimerWake.plan(for: [try task("at: 00:00\ndays: sun")])
        #expect(monday == .wake(time: TimeOfDay(hour: 23, minute: 55), days: [7]))
    }

    @Test func aProjectWithNoTimeOfDayHasNothingToWakeFor() throws {
        let every = TimerWake.plan(for: [try task("every: 1h")])
        guard case .none(let reason) = every else { Issue.record("expected none"); return }
        #expect(reason.contains("every so often"))
        guard case .none(let none) = TimerWake.plan(for: []) else { Issue.record("expected none"); return }
        #expect(none.contains("no task has a time of day"))
        #expect(every.command == nil && every.pmsetSchedule == nil)
        guard case .none = TimerWake.plan(for: [try task("fix: report")]) else { Issue.record("expected none"); return }
    }

    @Test func theRepeatingWakeIsReadFromPmsetsOwnWords() {
        let text = """
            Repeating power events:
              wakepoweron at 3:55AM weekdays only
            Scheduled power events:
             [0]  wake at 11/01/2026 08:28:13 by 'com.apple.alarm.user-invisible'
            """
        let morning = TimerWake.Repeating(time: TimeOfDay(hour: 3, minute: 55), days: "weekdays only")
        #expect(TimerWake.parseRepeating(text) == morning)
        let evening = "Repeating power events:\n  wake at 11:55PM every day\n"
        let late = TimerWake.Repeating(time: TimeOfDay(hour: 23, minute: 55), days: "every day")
        #expect(TimerWake.parseRepeating(evening) == late)
        let midnight = "Repeating power events:\n  wakepoweron at 12:05AM weekends only\n"
        #expect(TimerWake.parseRepeating(midnight)?.time == TimeOfDay(hour: 0, minute: 5))
        // Only the scheduled one-off events: no repeating wake.
        #expect(TimerWake.parseRepeating("Scheduled power events:\n [0] wake at 11/01/2026 08:28:13 by 'x'\n") == nil)
        #expect(TimerWake.parseRepeating("") == nil)
    }

    @Test func pmsetsWordsForTheDaySetsItNames() {
        #expect(TimerWake.pmsetWording(Set(2...6)) == "weekdays only")
        #expect(TimerWake.pmsetWording(Set(1...7)) == "every day")
        #expect(TimerWake.pmsetWording([1, 7]) == "weekends only")
        #expect(TimerWake.pmsetWording([2, 4]) == nil)
    }
}
