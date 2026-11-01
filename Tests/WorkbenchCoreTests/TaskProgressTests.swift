import Foundation
import Testing

@testable import WorkbenchCore

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    var value: [String] { lock.withLock { all } }
    func add(_ line: String) { lock.withLock { all.append(line) } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

@Suite struct TaskProgressTests {
    @Test func milestonesAlwaysPassAndToolLinesAreThrottled() {
        let lines = Lines()
        let clock = Clock()
        let progress = TaskProgress(now: { clock.now }, say: lines.add)
        progress.notice(.turnStarted(turn: 1, pid: 42, resume: false))
        progress.notice(.activity("Read a.txt"))
        progress.notice(.activity("Edit a.txt"))
        clock.advance(1)
        progress.notice(.activity("Edit b.txt"))
        clock.advance(2)
        progress.notice(.activity("Bash swift test"))
        progress.notice(.checkStarted(turn: 1, command: "make check"))
        progress.notice(.turnEnded(TurnReport.sample))
        #expect(lines.value == ["turn 1 started", "Read a.txt", "Bash swift test", "check started: make check"])
    }

    @Test func aLineIsOneBoundedLineWithNoControlCharacters() {
        let lines = Lines()
        let progress = TaskProgress(say: lines.add)
        progress.notice(.advisory("a\nb\u{1b}[31m " + String(repeating: "x", count: 1000)))
        let line = lines.value[0]
        #expect(line.count <= TaskProgress.maxLine && !line.contains("\n") && !line.contains("\u{1b}"))
        #expect(line.hasPrefix("note: a b"))
    }
}

extension TurnReport {
    /// A finished turn, for what only needs one.
    static var sample: TurnReport {
        TurnReport(
            turn: 1, result: .succeeded, exitCode: 0, signal: nil, durationMs: 1000, costUSD: nil, sessionID: "s",
            permissionDenials: 0, summary: nil, check: nil, verifier: nil)
    }
}
