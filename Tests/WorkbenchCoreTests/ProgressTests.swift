import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ProgressTests {
    private func event(_ seq: Int, _ ts: String, _ kind: EventKind, turn: Int = 1, _ data: JSONValue = [:]) -> Event {
        Event(seq: seq, ts: ts, turn: turn, kind: kind, data: data)
    }

    private func tool(_ name: String, _ summary: String) -> JSONValue {
        ["provider": "claude", "type": "tool", "name": .string(name), "summary": .string(summary)]
    }

    private var running: [Event] {
        [
            event(1, "2026-10-14T10:00:00.000Z", .turnStarted, ["session_id": "s"]),
            event(2, "2026-10-14T10:00:05.000Z", .agentActivity, tool("Edit", "examples.json")),
            event(4, "2026-10-14T10:00:10.000Z", .agentActivity, tool("Bash", "git push")),
            event(
                5, "2026-10-14T10:00:11.000Z", .agentActivity,
                ["provider": "claude", "type": "permission_denied", "tool": "Bash"]),
        ]
    }

    @Test func aRunningTurnCountsCallsAndRefusalsAndNamesTheLastEvent() {
        let state = ThreadState.derive(from: running, id: "t")
        #expect(state.openTurn == 1)
        #expect(state.progress.toolCalls == 2)
        #expect(state.progress.deniedCalls == 1)
        #expect(state.progress.lastEvent == "tool denied")
        #expect(state.progress.lastEventAt == "2026-10-14T10:00:11.000Z")
    }

    @Test func aTextOrThinkingMessageIsStillASignOfLife() {
        var events = running
        events.append(
            event(
                6, "2026-10-14T10:03:00.000Z", .agentActivity,
                ["provider": "claude", "type": "text", "text": "thinking it over"]))
        let progress = ThreadState.derive(from: events, id: "t").progress
        #expect(progress.lastEventAt == "2026-10-14T10:03:00.000Z")
        #expect(progress.toolCalls == 2)
    }

    @Test func elapsedAndQuietComeFromTheStampsAndTheClockPassedIn() throws {
        let progress = ThreadState.derive(from: running, id: "t").progress
        let now = try #require(Progress.parse("2026-10-14T10:04:12.000Z"))
        #expect(progress.elapsed(now: now) == 252)
        #expect(progress.quietFor(now: now) == 241)
        let lines = progress.lines(timeout: 1800, now: now)
        #expect(lines.contains("elapsed:   4m12s of 30m00s"))
        #expect(lines.contains { $0.hasPrefix("quiet:") })
        #expect(lines.contains("tools:     2 calls, 1 denied"))
    }

    @Test func aTurnThatMovedRecentlyIsNotQuiet() throws {
        let progress = ThreadState.derive(from: running, id: "t").progress
        let now = try #require(Progress.parse("2026-10-14T10:00:20.000Z"))
        #expect(!progress.lines(timeout: nil, now: now).contains { $0.hasPrefix("quiet:") })
    }

    @Test func aNewTurnStartsTheCountsAgain() {
        var events = running
        events.append(event(6, "2026-10-14T10:01:00.000Z", .turnEnded, ["result": "failed"]))
        events.append(event(7, "2026-10-14T10:02:00.000Z", .turnStarted, turn: 2, ["session_id": "s"]))
        let state = ThreadState.derive(from: events, id: "t")
        #expect(state.progress.toolCalls == 0)
        #expect(state.progress.deniedCalls == 0)
        #expect(state.progress.turnStartedAt == "2026-10-14T10:02:00.000Z")
    }

    @Test func stampsThatDoNotParseGiveNoNumbers() {
        let progress = Progress(turnStartedAt: "yesterday", lastEventAt: nil)
        #expect(progress.elapsed(now: Date()) == nil)
        #expect(progress.quietFor(now: Date()) == nil)
    }

    @Test(arguments: [(5.0, "5s"), (59.6, "1m00s"), (252.0, "4m12s"), (3720.0, "1h02m")])
    func durationsReadShort(seconds: Double, text: String) {
        #expect(Progress.duration(seconds) == text)
    }
}
