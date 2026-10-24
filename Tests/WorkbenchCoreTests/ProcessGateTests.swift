import Foundation
import Testing

/// Holders that stay inside the gate until the test lets each one go, and the most that were ever inside.
private final class Holders: @unchecked Sendable {
    private let lock = NSLock()
    private var inside: Set<Int> = []
    private var released: Set<Int> = []
    private var entered: [Int] = []
    private var peak = 0

    func enter(_ n: Int) {
        lock.withLock {
            inside.insert(n)
            entered.append(n)
            peak = max(peak, inside.count)
        }
    }

    func leave(_ n: Int) { lock.withLock { _ = inside.remove(n) } }
    func release(_ n: Int) { lock.withLock { _ = released.insert(n) } }
    func isReleased(_ n: Int) -> Bool { lock.withLock { released.contains(n) } }

    var count: Int { lock.withLock { inside.count } }
    var order: [Int] { lock.withLock { entered } }
    var most: Int { lock.withLock { peak } }

    /// Holds `gate` as holder `n` until `release(n)`.
    func hold(_ gate: ProcessGate, _ n: Int) async {
        await gate.withPermit {
            enter(n)
            _ = await pollUntil { isReleased(n) }
            leave(n)
        }
    }
}

private struct Boom: Error {}

@Suite struct ProcessGateTests {
    @Test func atMostNHoldersRunAndAWaiterGoesOnWhenAPermitFrees() async throws {
        let gate = ProcessGate(permits: 2)
        let holders = Holders()
        let first = [Task { await holders.hold(gate, 1) }, Task { await holders.hold(gate, 2) }]
        try #require(await pollUntil { holders.count == 2 })
        let third = Task { await holders.hold(gate, 3) }
        try #require(await pollUntil { gate.waiting == 1 })
        #expect(holders.count == 2 && gate.holders == 2, "the third waits while both permits are held")

        holders.release(1)
        #expect(await pollUntil { holders.order.contains(3) }, "the freed permit goes to the waiter")
        #expect(gate.holders == 2 && gate.waiting == 0)

        holders.release(2)
        holders.release(3)
        for task in first + [third] { await task.value }
        #expect(holders.most == 2)
        #expect(gate.holders == 0)
    }

    @Test func manyHoldersNeverExceedThePermits() async {
        let gate = ProcessGate(permits: 3)
        let holders = Holders()
        let tasks = (1...12).map { n in Task { await holders.hold(gate, n) } }
        for n in 1...12 { holders.release(n) }
        for task in tasks { await task.value }
        #expect(holders.order.count == 12)
        #expect(holders.most <= 3)
        #expect(gate.holders == 0 && gate.waiting == 0)
    }

    @Test func aHolderThatThrowsGivesItsPermitBack() async throws {
        let gate = ProcessGate(permits: 1)
        await #expect(throws: Boom.self) {
            try await gate.withPermit { () async throws in throw Boom() }
        }
        #expect(gate.holders == 0)
        let ran = await gate.withPermit { true }
        #expect(ran)
    }

    @Test func aWaiterGetsThePermitOfAHolderThatThrows() async throws {
        let gate = ProcessGate(permits: 1)
        let holders = Holders()
        let thrower = Task {
            try await gate.withPermit { () async throws in
                holders.enter(1)
                _ = await pollUntil { holders.isReleased(1) }
                throw Boom()
            }
        }
        try #require(await pollUntil { holders.count == 1 })
        let waiter = Task { await holders.hold(gate, 2) }
        try #require(await pollUntil { gate.waiting == 1 })

        holders.release(1)
        await #expect(throws: Boom.self) { try await thrower.value }
        #expect(await pollUntil { holders.order.contains(2) })
        holders.release(2)
        await waiter.value
        #expect(gate.holders == 0)
    }

    @Test func aNestedPermitOfTheSameGateDoesNotWaitForItself() async {
        let gate = ProcessGate(permits: 1)
        let inner = await gate.withPermit { await gate.withPermit { gate.holders } }
        #expect(inner == 1)
        #expect(!gate.isHeld && gate.holders == 0)
    }

    @Test func theSharedGateIsSizedFromTheCoresUnlessTheVariableSaysOtherwise() {
        let environment = ProcessInfo.processInfo.environment
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #expect(ProcessGate.shared.permits == ProcessGate.permits(environment: environment, cores: cores))
    }
}

/// The trait holds a permit of the shared gate for each test, so a gated fixture builds inside it.
@Suite(.processGate) struct ProcessGateTraitTests {
    @Test func aGatedTestHoldsASharedPermit() {
        #expect(ProcessGate.shared.isHeld)
        #expect(ProcessGate.shared.holders >= 1)
    }

    @Test func aTaskStartedByAGatedTestHoldsItToo() async {
        let held = await Task { ProcessGate.shared.isHeld }.value
        #expect(held)
    }

    @Test(arguments: [1, 2]) func eachCaseOfAParameterizedTestHoldsIt(_ n: Int) {
        #expect(ProcessGate.shared.isHeld, "case \(n)")
    }
}

@Suite struct ProcessGatePermitsTests {
    @Test func theVariableWinsWhenItIsAPositiveNumber() {
        #expect(ProcessGate.permits(environment: ["WORKBENCH_TEST_PERMITS": "7"], cores: 3) == 7)
        #expect(ProcessGate.permits(environment: ["WORKBENCH_TEST_PERMITS": "7", "CI": "true"], cores: 3) == 7)
    }

    @Test(arguments: ["0", "-2", "many", ""])
    func aBadValueIsIgnored(_ value: String) {
        #expect(ProcessGate.permits(environment: ["WORKBENCH_TEST_PERMITS": value, "CI": "true"], cores: 3) == 3)
    }

    @Test func withoutTheVariableItIsOnePerCoreWithAFloorOfTwo() {
        #expect(ProcessGate.permits(environment: [:], cores: 11) == 11)
        #expect(ProcessGate.permits(environment: ["CI": "true"], cores: 3) == 3)
        #expect(ProcessGate.permits(environment: [:], cores: 1) == 2)
    }
}
