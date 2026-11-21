import Foundation
import Testing

@testable import WorkbenchCore

private let head = String(repeating: "a", count: 40)

private func ev(_ seq: Int, _ kind: EventKind, _ data: JSONValue = [:]) -> Event {
    Event(seq: seq, ts: "2026-11-21T10:00:\(String(format: "%02d", seq % 60)).000Z", turn: 0, kind: kind, data: data)
}

private func facts(
    pr: Bool = true, head sha: String = head, decision: String? = nil, merged: Bool = false, closed: Bool = false,
    checks: [(String, String)]? = [("test", "pass")], checksError: String? = nil, review: JSONValue? = nil, started: Bool = false,
    live: (state: PRState, head: String)? = (.open, head), liveError: String? = nil
) -> SeriesStepFacts {
    var events: [Event] = []
    if pr { events.append(ev(1, .prOpened, ["number": 7, "url": "https://example.test/pull/7", "head_sha": .string(sha)])) }
    if started { events.append(ev(2, .prReviewStarted, ["round": 1, "pr": 7, "head_sha": .string(head)])) }
    if let review { events.append(ev(3, .prReviewFinished, review)) }
    if merged { events.append(ev(4, .prMerged, ["number": 7])) }
    if closed { events.append(ev(4, .prClosed, ["number": 7])) }
    if let decision { events.append(ev(5, .reviewDecision, ["decision": .string(decision)])) }
    return SeriesStepFacts(
        thread: "g-1-x", state: ThreadState.derive(from: events, id: "g-1-x"),
        checks: checks.map { PRChecksSummary(checks: $0.map { PRCheck(name: $0.0, bucket: $0.1) }) }, checksError: checksError,
        live: live, liveError: liveError)
}

private let cleanReview: JSONValue = ["round": 1, "pr": 7, "head_sha": .string(head), "ok": true, "verdict": "clean"]

struct SeriesStateTests {
    @Test func noThreadIsPending() {
        #expect(SeriesScheduler.state(nil) == .pending)
    }

    @Test func aThreadWithoutAPullRequestIsRunningUntilItEndsWithoutOne() {
        #expect(SeriesScheduler.state(facts(pr: false, checks: nil)) == .running(thread: "g-1-x"))
        guard case .stopped(_, let reason) = SeriesScheduler.state(facts(pr: false, decision: "discarded", checks: nil)) else {
            Issue.record("expected stopped")
            return
        }
        #expect(reason.contains("discarded"))
        guard case .stopped(_, let accepted) = SeriesScheduler.state(facts(pr: false, decision: "accepted", checks: nil)) else {
            Issue.record("expected stopped")
            return
        }
        #expect(accepted.contains("not shipped"))
    }

    @Test func passedChecksAndACleanReviewOfTheHeadAreClean() {
        #expect(SeriesScheduler.state(facts(review: cleanReview)).isClean)
        #expect(SeriesScheduler.state(facts(checks: [("a", "pass"), ("b", "skipping")], review: cleanReview)).isClean)
    }

    @Test func aMergedPullRequestIsCleanWithoutReadingChecks() {
        #expect(SeriesScheduler.state(facts(merged: true, checks: nil)).isClean)
    }

    @Test func aMergeOrACloseOnGitHubCountsEvenWhenNoCommandRecordedIt() {
        #expect(SeriesScheduler.state(facts(checks: nil, live: (.merged, head))).isClean)
        guard case .stopped(_, let reason) = SeriesScheduler.state(facts(review: cleanReview, live: (.closed, head))) else {
            Issue.record("a pull request closed on GitHub is not clean")
            return
        }
        #expect(reason.contains("closed"))
    }

    @Test func aPullRequestThatCouldNotBeReadIsNeverClean() {
        for f in [facts(review: cleanReview, live: nil), facts(review: cleanReview, live: nil, liveError: "gh failed")] {
            guard case .waiting = SeriesScheduler.state(f) else {
                Issue.record("expected waiting")
                continue
            }
        }
    }

    @Test func aCommitPushedAfterTheReviewIsNotCleanEvenWhenItsChecksPass() {
        let pushed = String(repeating: "c", count: 40)
        guard case .waiting(_, let why) = SeriesScheduler.state(facts(review: cleanReview, live: (.open, pushed))) else {
            Issue.record("the review was of an older commit")
            return
        }
        #expect(why.contains("older commit"))
    }

    @Test func aClosedPullRequestStops() {
        guard case .stopped(_, let reason) = SeriesScheduler.state(facts(closed: true, checks: nil)) else {
            Issue.record("expected stopped")
            return
        }
        #expect(reason.contains("closed"))
    }

    @Test func checksThatAreMissingPendingOrUnreadableWait() {
        let unready = [
            facts(checks: []), facts(checks: [("t", "pending")]),
            facts(checks: nil, checksError: "gh failed"), facts(checks: nil),
        ]
        for f in unready {
            guard case .waiting = SeriesScheduler.state(f) else {
                Issue.record("expected waiting")
                continue
            }
        }
    }

    @Test func aCancelledOrFailedCheckStopsOnlyWhenNothingIsStillRunning() {
        let cancelled = facts(checks: [("t", "cancel"), ("s", "pass")], review: cleanReview)
        guard case .stopped(_, let reason) = SeriesScheduler.state(cancelled) else {
            Issue.record("a cancelled check is not clean")
            return
        }
        #expect(reason.contains("t"))
        guard case .waiting = SeriesScheduler.state(facts(checks: [("t", "fail"), ("s", "pending")], review: cleanReview)) else {
            Issue.record("a failure with a check still running waits")
            return
        }
    }

    @Test func theReviewMustBeCleanAndOfTheCommitThatIsOpen() {
        guard case .waiting = SeriesScheduler.state(facts()) else {
            Issue.record("no review yet is waiting")
            return
        }
        guard case .waiting = SeriesScheduler.state(facts(started: true)) else {
            Issue.record("a running round waits")
            return
        }
        let fix: JSONValue = ["round": 1, "pr": 7, "head_sha": .string(head), "ok": true, "verdict": "fix"]
        guard case .waiting = SeriesScheduler.state(facts(review: fix)) else {
            Issue.record("fix is not clean")
            return
        }
        let other = String(repeating: "b", count: 40)
        guard case .waiting(_, let why) = SeriesScheduler.state(facts(review: cleanReview, live: (.open, other))) else {
            Issue.record("a review of an older commit waits")
            return
        }
        #expect(why.contains("older commit"))
        let failed: JSONValue = ["round": 2, "pr": 7, "head_sha": .string(head), "ok": false, "reason": "codex was at capacity"]
        guard case .stopped(_, let reason) = SeriesScheduler.state(facts(review: failed)) else {
            Issue.record("a round with no verdict stops")
            return
        }
        #expect(reason.contains("capacity"))
    }
}

struct SeriesSchedulerTests {
    private func definition() throws -> SeriesDefinition {
        try SeriesDefinition.parse(
            """
            ## 1
            project: /a
            goal: a.md
            ## 2
            project: /a
            goal: b.md
            base: after 1
            ## 3
            project: /b
            goal: c.md
            after: 1
            """, name: "s")
    }

    @Test func aStepStartsWhenEveryStepItWaitsForIsClean() throws {
        let d = try definition()
        #expect(SeriesScheduler.ready(d, states: [:]) == [1])
        let one = SeriesStepState.clean(thread: "t", pullRequest: nil)
        #expect(SeriesScheduler.ready(d, states: [1: .running(thread: "t")]) == [])
        #expect(SeriesScheduler.ready(d, states: [1: .waiting(thread: "t", reason: "r")]) == [])
        #expect(SeriesScheduler.ready(d, states: [1: one]) == [2, 3])
        #expect(SeriesScheduler.ready(d, states: [1: one, 2: .running(thread: "u")]) == [3])
    }

    @Test func nothingStartsWhileAnyStepIsStopped() throws {
        let d = try definition()
        let stopped = SeriesStepState.stopped(thread: "t", reason: "checks failed: test")
        #expect(SeriesScheduler.ready(d, states: [1: .clean(thread: "t", pullRequest: nil), 2: stopped]) == [])
        #expect(SeriesScheduler.stoppedStep(d, states: [2: stopped])?.step == 2)
        #expect(SeriesScheduler.stoppedStep(d, states: [:]) == nil)
    }

    @Test func blockedByNamesTheStepsNotYetClean() throws {
        let d = try definition()
        #expect(SeriesScheduler.blockedBy(d.steps[2], states: [:]) == [1])
        #expect(SeriesScheduler.blockedBy(d.steps[2], states: [1: .clean(thread: "t", pullRequest: nil)]).isEmpty)
    }
}

struct SeriesStepLogTests {
    @Test func theLatestRecordOfEachStepIsReadAndBadLinesAreSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        let project = Project(root: root)
        try FileManager.default.createDirectory(at: project.seriesDirectory("s"), withIntermediateDirectories: true)
        let log = SeriesStepLog(project: project, series: "s")
        #expect(log.read().isEmpty)
        try log.append(SeriesRecord(step: 1, thread: "g-1-a", at: "t1"))
        try log.append(SeriesRecord(step: 2, thread: "g-1-b", at: "t2"))
        try log.append(SeriesRecord(step: 1, thread: "g-1-c", at: "t3"))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"step\":3,\"thread\":\"../x\"}\n".utf8))
        try handle.close()
        let read = log.read()
        #expect(read[1]?.thread == "g-1-c")
        #expect(read[2]?.thread == "g-1-b")
        #expect(read[3] == nil)
    }
}
