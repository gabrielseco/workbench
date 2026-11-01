import Foundation

/// When the machine should wake for the tasks. macOS keeps one repeating wake event (`pmset repeat`), so it is the earliest time any task
/// needs, five minutes early, on every day any task runs. Workbench only computes it: changing it needs `sudo`, and the person runs it.
public enum TimerWake {
    public static let leadMinutes = 5

    public enum Plan: Equatable, Sendable {
        case wake(time: TimeOfDay, days: Set<Int>)
        /// No task has a time of day, so there is nothing to wake for.
        case none(reason: String)

        /// `MTWRF 03:55:00`, the form `pmset repeat` takes.
        public var pmsetSchedule: String? {
            guard case .wake(let time, let days) = self else { return nil }
            return TimerWake.letters(days) + String(format: " %02d:%02d:00", time.hour, time.minute)
        }

        public var command: String? { pmsetSchedule.map { "sudo pmset repeat wakeorpoweron " + $0 } }
    }

    /// `pmset`'s day letters, by `Calendar` weekday (1 = Sunday): M T W R F S U.
    static let letterByWeekday: [Int: Character] = [2: "M", 3: "T", 4: "W", 5: "R", 6: "F", 7: "S", 1: "U"]

    static func letters(_ days: Set<Int>) -> String {
        String("MTWRFSU".filter { letter in days.contains { letterByWeekday[$0] == letter } })
    }

    public static func plan(for tasks: [TaskDefinition]) -> Plan {
        var earliest: TimeOfDay?
        var days = Set<Int>()
        for case .daily(let time, let taskDays)? in tasks.map(\.schedule) {
            if earliest.map({ time.hour * 60 + time.minute < $0.hour * 60 + $0.minute }) ?? true { earliest = time }
            days.formUnion(taskDays)
        }
        guard let first = earliest, !days.isEmpty else {
            let hasInterval = tasks.contains { if case .every? = $0.schedule { true } else { false } }
            return .none(
                reason: hasInterval
                    ? "tasks that run every so often have no time of day to wake for; the machine must be awake when they are due"
                    : "no task has a time of day (at:), so there is nothing to wake for")
        }
        var minutes = first.hour * 60 + first.minute - leadMinutes
        var wakeDays = days
        if minutes < 0 {
            // Just after midnight: the wake is late the evening before, so each day moves back one.
            minutes += 24 * 60
            wakeDays = Set(days.map { $0 == 1 ? 7 : $0 - 1 })
        }
        return .wake(time: TimeOfDay(hour: minutes / 60, minute: minutes % 60), days: wakeDays)
    }

    /// What `pmset -g sched` says about the repeating wake: its time and its days as pmset words them.
    public struct Repeating: Equatable, Sendable {
        public var time: TimeOfDay
        public var days: String
    }

    /// From `  wakepoweron at 3:55AM weekdays only` (or `wake at ...`, `every day`, `weekends only`). Nil when there is no repeating event.
    public static func parseRepeating(_ text: String) -> Repeating? {
        var inRepeating = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Repeating power events") { inRepeating = true; continue }
            if line.hasPrefix("Scheduled power events") { inRepeating = false }
            guard inRepeating, line.hasPrefix("wake"),
                let match = line.firstMatch(of: #/at ([0-9]{1,2}):([0-9]{2})\s*(AM|PM)?\s*(.*)/#),
                var hour = Int(match.1), let minute = Int(match.2)
            else { continue }
            if let half = match.3 {
                hour = hour % 12 + (half == "PM" ? 12 : 0)
            }
            let days = String(match.4).trimmingCharacters(in: .whitespaces)
            return Repeating(time: TimeOfDay(hour: hour, minute: minute), days: days)
        }
        return nil
    }

    /// pmset's own wording for a day set, where it is known: `weekdays only`, `weekends only`, `every day`. Nil for any other set.
    public static func pmsetWording(_ days: Set<Int>) -> String? {
        if days == Set(1...7) { return "every day" }
        if days == Set(2...6) { return "weekdays only" }
        if days == [1, 7] { return "weekends only" }
        return nil
    }
}
