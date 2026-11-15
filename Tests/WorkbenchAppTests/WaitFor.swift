import Testing

@testable import WorkbenchApp

/// Waits until `condition` holds, and fails the test (rather than hanging it) if it has not by `timeout`.
@MainActor func waitFor(
    _ what: String = "the state the test needs", timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async {
    let reached = await wait(while: { !condition() }, atMost: timeout, every: .milliseconds(10))
    #expect(reached, "timed out waiting for \(what)", sourceLocation: sourceLocation)
}
