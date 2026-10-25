import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct AdopterProbeTests {
    private func ledger() -> AdopterLedger {
        AdopterLedger(file: FileManager.default.temporaryDirectory.appendingPathComponent("wb-ledger-\(UUID().uuidString)"))
    }

    private let work = URL(fileURLWithPath: "/tmp/wb-probe-rule-\(UUID().uuidString)/worktree")

    @Test func aProbeThatNeverFinishesIsKilledAndReapedNotLeftBehind() throws {
        let outcome = AdopterProbe.measure(on: platform, script: "exec sleep 60", patience: 5)
        let shell = try #require(outcome.shell)
        #expect(outcome.adopter == nil)
        // A zombie would still answer signal 0; only a process that was killed and waited for does not.
        #expect(kill(shell, 0) == -1 && errno == ESRCH, "the probe's shell is gone, not left running or unreaped")
    }

    @Test func aProbeThatFinishesNamesTheNewParentOfTheOrphan() throws {
        let outcome = AdopterProbe.measure(on: platform)
        let adopter = try #require(outcome.adopter)
        let live = adopter.pid == 1 || platform.member(for: adopter.pid) == adopter
        #expect(live, "PID 1, or a live process identified by when it started")
    }

    @Test func anAdopterAnEarlierRunRecordedStaysOneAfterAnotherIsMeasured() {
        // The runner started under subreaper 900 and died; the thread is resumed from under subreaper 1000.
        let file = ledger()
        let machine = Machine([900: .init(parent: 1, cwd: "/"), 1000: .init(parent: 1, cwd: "/")])
        file.record(ProcessMember(pid: 900, startSeconds: 100, startMicros: 0), on: machine)
        let cache = AdopterCache(ledger: file) { ProcessMember(pid: 1000, startSeconds: 100, startMicros: 0) }
        machine.adopters = cache.adopters(on: machine)
        #expect(machine.adopters == [1, 900, 1000])
    }

    @Test func aLeftoverUnderTheEarlierSubreaperIsSweptAfterResumingUnderAnother() {
        let file = ledger()
        let machine = Machine([
            900: .init(parent: 1, cwd: "/"), 1000: .init(parent: 1, cwd: "/"),
            500: .init(parent: 900, cwd: work.path),
        ])
        file.record(ProcessMember(pid: 900, startSeconds: 100, startMicros: 0), on: machine)
        let cache = AdopterCache(ledger: file) { ProcessMember(pid: 1000, startSeconds: 100, startMicros: 0) }
        machine.adopters = cache.adopters(on: machine)
        #expect(Set(OrphanSweeper.orphans(inside: work, on: machine).map(\.pid)) == [500])
    }

    @Test func aRecordedPidThatWasReusedByAnotherProcessIsNotAnAdopter() {
        let file = ledger()
        let machine = Machine([900: .init(parent: 1, cwd: "/")])
        file.record(ProcessMember(pid: 900, startSeconds: 100, startMicros: 0), on: machine)
        machine.table[900]?.start = 555
        #expect(file.recorded(on: machine).isEmpty)
    }

    @Test func theLedgerKeepsAFewEntriesAndIgnoresAFileThatIsNotWhatItWrote() throws {
        let file = ledger()
        var table: [pid_t: Machine.Entry] = [:]
        for pid: pid_t in 100..<120 { table[pid] = .init(parent: 1, cwd: "/") }
        let machine = Machine(table)
        for pid: pid_t in 100..<120 { file.record(ProcessMember(pid: pid, startSeconds: 100, startMicros: 0), on: machine) }
        #expect(file.recorded(on: machine).count == AdopterLedger.capacity)
        try "not a ledger \n1 2\n-5 x y".write(to: file.file, atomically: true, encoding: .utf8)
        #expect(file.recorded(on: machine).isEmpty)
    }

    @Test func aFailedMeasurementIsTriedAgainLaterAndASuccessIsKept() {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let machine = Machine([900: .init(parent: 1, cwd: "/")])
        let cache = AdopterCache(ledger: ledger(), retryAfter: 0) {
            calls.count += 1
            return calls.count == 1 ? nil : ProcessMember(pid: 900, startSeconds: 100, startMicros: 0)
        }
        #expect(cache.adopters(on: machine) == [1], "the first measurement failed: PID 1 alone")
        #expect(cache.adopters(on: machine) == [1, 900], "the next sweep measures again")
        _ = cache.adopters(on: machine)
        #expect(calls.count == 2, "a measurement that worked is not repeated")
    }

    @Test func aFailedMeasurementWaitsBeforeTryingAgain() {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let cache = AdopterCache(ledger: ledger(), retryAfter: 3600) {
            calls.count += 1
            return nil
        }
        let machine = Machine([:])
        _ = cache.adopters(on: machine)
        _ = cache.adopters(on: machine)
        #expect(calls.count == 1, "a stuck probe does not cost its wait on every sweep")
    }

    @Test func anAdopterThatExitedIsMeasuredAgain() {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let machine = Machine([900: .init(parent: 1, cwd: "/"), 1000: .init(parent: 1, cwd: "/")])
        let cache = AdopterCache(ledger: ledger(), retryAfter: 0) {
            calls.count += 1
            return ProcessMember(pid: calls.count == 1 ? 900 : 1000, startSeconds: 100, startMicros: 0)
        }
        #expect(cache.adopters(on: machine) == [1, 900])
        machine.table[900] = nil
        #expect(cache.adopters(on: machine) == [1, 1000], "its orphans went to the next subreaper up")
    }
}
