import Foundation

/// Waits while `condition` holds, giving up at `deadline`. Returns whether the condition ended (false: it still held at the deadline).
@MainActor @discardableResult
func wait(
    while condition: () -> Bool, until deadline: ContinuousClock.Instant, every interval: Duration = .milliseconds(50)
) async -> Bool {
    while condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: interval)
    }
    return true
}

/// The same for a budget counted from now.
@MainActor @discardableResult
func wait(while condition: () -> Bool, atMost timeout: Duration, every interval: Duration = .milliseconds(50)) async -> Bool {
    await wait(while: condition, until: ContinuousClock.now + timeout, every: interval)
}
