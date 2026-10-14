import Foundation

/// How long a test waits for something another process has to do.
///
/// The suites run in parallel and almost every test spawns processes (git, sh, the fake claude), so a step
/// that takes milliseconds alone can take many seconds on a loaded CI runner: a stop to exit took 6.8 s
/// there. A wait returns the moment its condition holds, so a long limit costs a passing test nothing; it
/// only bounds a real hang. An assertion that something finished *within N seconds* is a measurement of
/// the runner, not of the code: assert what happened (escalated or not, how it ended) and use this as the
/// ceiling.
enum Patience {
    static let limit: TimeInterval = 60
}

/// Polls `condition` until it holds or `timeout` passes.
func pollUntil(timeout: TimeInterval = Patience.limit, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
