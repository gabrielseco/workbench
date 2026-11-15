import Testing

@testable import WorkbenchApp

/// Waits until `condition` holds. After `timeout` the test fails and stops here, so what follows never runs against a state that
/// did not come (it could block on it and hang the suite).
@MainActor func waitFor(
    _ what: String = "the state the test needs", timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async throws {
    let reached = await wait(while: { !condition() }, atMost: timeout, every: .milliseconds(10))
    try #require(reached, "timed out waiting for \(what)", sourceLocation: sourceLocation)
}
