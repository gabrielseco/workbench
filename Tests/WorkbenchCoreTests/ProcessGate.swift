import Foundation
import Testing

/// Lets only a few tests that spawn processes run at once.
///
/// `swift test` starts every test together, and on a 3-core CI runner hundreds of them building git
/// repositories and starting children at the same time starved each other: a fixture took a minute and the
/// wait after it ran out (#161 made the waits longer; it did not help). A test that holds a permit builds its
/// fixture and runs its processes with only a few others competing, so its waits measure the code again. The
/// gate only orders tests; `Patience.limit` stays the ceiling of every wait.
final class ProcessGate: @unchecked Sendable {
    /// Sized from the machine and the environment, see `permits(environment:cores:)`.
    static let shared = ProcessGate(
        permits: permits(environment: ProcessInfo.processInfo.environment, cores: ProcessInfo.processInfo.activeProcessorCount))

    /// How many process-spawning tests run at once. `WORKBENCH_TEST_PERMITS` wins when it is a positive number
    /// (to measure a size; more than one per core made the run no faster and the hang and timeout tests flaky,
    /// docs/plan/P17-faster-tests.md). Otherwise one per core, at least two so a waiting test never runs alone.
    static func permits(environment: [String: String], cores: Int) -> Int {
        if let text = environment["WORKBENCH_TEST_PERMITS"], let value = Int(text), value > 0 { return value }
        return max(2, cores)
    }

    /// The gates this task holds a permit of; a nested `withPermit` on one of them must not wait for itself.
    @TaskLocal private static var held: Set<ObjectIdentifier> = []

    let permits: Int
    private let lock = NSLock()
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        precondition(permits > 0, "a gate with no permits lets nothing run")
        self.permits = permits
        available = permits
    }

    /// Runs `body` holding a permit, waiting for one first; the permit goes back however `body` ends.
    func withPermit<T>(_ body: () async throws -> T) async rethrows -> T {
        if isHeld { return try await body() }
        await acquire()
        defer { release() }
        return try await Self.$held.withValue(Self.held.union([ObjectIdentifier(self)])) { try await body() }
    }

    /// Whether the current task runs inside `withPermit` of this gate.
    var isHeld: Bool { Self.held.contains(ObjectIdentifier(self)) }

    var holders: Int { lock.withLock { permits - available } }

    var waiting: Int { lock.withLock { waiters.count } }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                guard available > 0 else {
                    waiters.append(continuation)
                    return false
                }
                available -= 1
                return true
            }
            if now { continuation.resume() }
        }
    }

    private func release() {
        // A waiter takes the permit over directly, so a test arriving now cannot overtake it.
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiters.isEmpty {
                available += 1
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

/// `@Suite(.processGate)`: each test of the suite, fixture included, runs holding a permit of the shared gate.
struct ProcessGateTrait: SuiteTrait, TestTrait, TestScoping {
    // Recursive so the scope wraps each test on its own, not the whole suite at once.
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await ProcessGate.shared.withPermit { try await function() }
    }
}

extension Trait where Self == ProcessGateTrait {
    static var processGate: Self { Self() }
}

/// Records an issue when a test spawns processes from a shared fixture without the gate.
func expectProcessGate(_ fixture: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !ProcessGate.shared.isHeld {
        Issue.record("\(fixture) spawns processes: give the suite @Suite(.processGate)", sourceLocation: sourceLocation)
    }
}
