import Foundation

/// Keeps a thread's row where it is drawn until its new section has lasted `delay` (and the pointer is off the rail), so a thread that
/// flips between working and needs you during a fix loop does not jump around the list. Only the placement waits: the row's mark, words
/// and spend are always the live ones. Pure state, driven by `update`, so it is tested without a window or a clock.
struct InboxSectionHold {
    /// How long a new section must hold before the row moves to it.
    static let delay: TimeInterval = 3

    /// The section each row is drawn in.
    private(set) var shown: [String: InboxSection] = [:]
    /// The section a row's state gives that differs from the one it is drawn in, and since when it has given that one.
    private var differing: [String: (section: InboxSection, since: Date)] = [:]

    /// Settles the drawn sections towards `target` (row id → the section its state gives).
    /// - Parameter frozen: the pointer is on the rail; rows stay put, and new and gone ones still come and go.
    /// - Returns: when the next waiting row is due to move, nil when none waits or while frozen (the pointer leaving asks again).
    @discardableResult
    mutating func update(target: [String: InboxSection], now: Date, frozen: Bool = false) -> Date? {
        shown = shown.filter { target[$0.key] != nil }
        differing = differing.filter { target[$0.key] != nil }
        for (id, section) in target {
            guard let drawn = shown[id] else {
                shown[id] = section  // a row seen for the first time is drawn where it belongs
                continue
            }
            if drawn == section {
                differing[id] = nil
                continue
            }
            // Another destination restarts the clock: the delay is for the section the row would move to.
            let since = differing[id].flatMap { $0.section == section ? $0.since : nil } ?? now
            differing[id] = (section, since)
            if !frozen, now.timeIntervalSince(since) >= Self.delay {
                shown[id] = section
                differing[id] = nil
            }
        }
        guard !frozen else { return nil }
        return differing.values.map(\.since).min().map { $0.addingTimeInterval(Self.delay) }
    }
}

/// The inbox's state that outlives its views.
@MainActor @Observable final class InboxRailState {
    /// The projects whose Done section is open (by path); closed unless the person opened it.
    var doneOpen: Set<String> = []
    var hold = InboxSectionHold()
    /// The pointer is on the rail: rows stay put.
    var hovered = false
}
