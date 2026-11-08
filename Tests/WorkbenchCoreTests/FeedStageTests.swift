import Foundation
import Testing

@testable import WorkbenchCore

/// A review stage other than the PR review (the project's `design`) is on the feed and in the state, not only in the log.
@Suite struct FeedStageTests {
    private func ev(_ seq: Int, _ kind: EventKind, _ data: JSONValue = [:]) -> Event {
        Event(seq: seq, ts: "2026-11-02T10:00:\(String(format: "%02d", seq % 60)).000Z", turn: 1, kind: kind, data: data)
    }

    private let created = Event(seq: 1, ts: "2026-11-02T10:00:01.000Z", turn: 0, kind: .threadCreated, data: ["base": "main"])

    private func items(_ events: [Event]) -> [FeedItem] {
        var data = Data()
        for event in events {
            data.append(try! JSONEncoder().encode(event))
            data.append(UInt8(ascii: "\n"))
        }
        let read = EventLogReader.parse(data)
        let state = ThreadState.derive(from: read.events, id: "t")
        let spine = ThreadSpine.derive(state: state, approval: nil)
        return Feed.items(
            contents: read, goal: nil, state: state, spine: spine,
            attention: Attention.derive(spine: spine, state: state), runnerAlive: true)
    }

    @Test func aReviewStageIsAnItemWithTheScreenshotsItWasGiven() {
        let all = items([
            created,
            ev(2, .reviewStageStarted, ["stage": "design", "round": 1, "proof": ["list.png", "feed.png"]]),
            ev(3, .reviewStageFinished, ["stage": "design", "round": 1, "verdict": "clean", "ok": true]),
            ev(4, .reviewStageFinished, ["stage": "other", "round": 1, "verdict": "skipped", "ok": false]),
        ])
        #expect(
            all.contains {
                $0.kind == .stage(name: "design", round: 1, verdict: "clean", ok: true, proof: ["list.png", "feed.png"])
            })
        #expect(
            all.contains { $0.kind == .stage(name: "other", round: 1, verdict: "skipped", ok: false, proof: []) },
            "a skip has no start and so no screenshots")
    }

    @Test func aSkipAfterARoundThatReadScreenshotsHasNone() {
        let all = items([
            created,
            ev(2, .reviewStageStarted, ["stage": "design", "round": 1, "proof": ["list.png"]]),
            ev(3, .reviewStageFinished, ["stage": "design", "round": 1, "verdict": "clean", "ok": true]),
            ev(4, .reviewStageFinished, ["stage": "design", "round": 2, "verdict": "skipped", "ok": false]),
        ])
        #expect(all.contains { $0.kind == .stage(name: "design", round: 2, verdict: "skipped", ok: false, proof: []) })
    }

    @Test func aReviewStageIsRunningFromItsStartToItsFinish() {
        let started = ev(2, .reviewStageStarted, ["stage": "design", "round": 1])
        #expect(ThreadState.derive(from: [created, started], id: "t").review.runningStages == ["design"])
        let finished = ev(3, .reviewStageFinished, ["stage": "design", "round": 1, "ok": true])
        #expect(ThreadState.derive(from: [created, started, finished], id: "t").review.runningStages.isEmpty)
        let skip = ev(2, .reviewStageFinished, ["stage": "design", "ok": false])
        let skipped = ThreadState.derive(from: [created, skip], id: "t")
        #expect(skipped.review.runningStages.isEmpty, "a finish with no start opens nothing")
    }
}
