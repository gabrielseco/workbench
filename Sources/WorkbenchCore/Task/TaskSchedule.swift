import Foundation

public struct TimeOfDay: Equatable, Sendable {
    public var hour: Int
    public var minute: Int

    public var text: String { String(format: "%02d:%02d", hour, minute) }
}

/// When a task is due. A task with no schedule is run by hand only.
public enum TaskSchedule: Equatable, Sendable {
    /// At a time of day on some days. `days` are `Calendar` weekday numbers, 1 = Sunday.
    case daily(at: TimeOfDay, days: Set<Int>)
    /// Every so many seconds after the last run.
    case every(seconds: Int)

    public static let minimumInterval = 300
    public static let maximumInterval = 30 * 86_400

    /// The first moment after `since` the task is due. `since` is the start of its last run, or the moment it was
    /// approved when it never ran. A moment that is already past means the task is due now: a machine that was
    /// off for three days gets one run, not three, because the next slot is counted from the run that caught up.
    public func nextDue(since: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .every(let seconds):
            return since.addingTimeInterval(TimeInterval(seconds))
        case .daily(let time, let days):
            guard !days.isEmpty else { return nil }
            var day = calendar.startOfDay(for: since)
            // A week and the day it started on cover every weekday once.
            for _ in 0..<8 {
                let weekday = calendar.component(.weekday, from: day)
                if days.contains(weekday),
                    let slot = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day),
                    slot > since {
                    return slot
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = next
            }
            return nil
        }
    }

    public func isDue(since: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = nextDue(since: since, calendar: calendar) else { return false }
        return due <= now
    }

    static let weekdayNames = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]

    /// One line for `task list`: "weekdays 04:00", "mon,wed 09:30", "every 1h".
    public var summary: String {
        switch self {
        case .every(let seconds):
            if seconds % 86_400 == 0 { return "every \(seconds / 86_400)d" }
            if seconds % 3600 == 0 { return "every \(seconds / 3600)h" }
            return "every \(seconds / 60)m"
        case .daily(let time, let days):
            let label: String
            if days == Set(1...7) {
                label = "daily"
            } else if days == Set(2...6) {
                label = "weekdays"
            } else {
                let names = Self.weekdayNames.sorted { $0.value < $1.value }
                label = names.filter { days.contains($0.value) }.map(\.key).joined(separator: ",")
            }
            return "\(label) \(time.text)"
        }
    }
}
