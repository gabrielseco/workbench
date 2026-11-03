import Foundation
import Testing

@testable import WorkbenchCore

/// The agent's own task list in the feed (design parity 8): one row per turn, the list as the turn left it.
@Suite struct FeedPlanTests {
    private func ev(_ seq: Int, _ turn: Int, _ kind: EventKind, _ data: JSONValue = [:]) -> Event {
        Event(seq: seq, ts: "2026-11-02T10:00:\(String(format: "%02d", seq % 60)).000Z", turn: turn, kind: kind, data: data)
    }

    private func activity(_ seq: Int, _ type: String, _ fields: [String: JSONValue] = [:]) -> Event {
        var data = fields
        data["type"] = .string(type)
        data["provider"] = "claude"
        return ev(seq, 1, .agentActivity, .object(data))
    }

    private func feed(_ events: [Event]) -> [FeedItem] {
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

    private let created = Event(seq: 1, ts: "2026-11-02T10:00:01.000Z", turn: 0, kind: .threadCreated, data: ["base": "main"])

    private func plan(_ seq: Int, _ items: [(String, String)]) -> Event {
        activity(seq, "plan", ["items": .array(items.map { .object(["text": .string($0.0), "status": .string($0.1)]) })])
    }

    @Test func aTurnsTaskListIsOneRowWhereItFirstAppearedWithTheLastList() {
        let items = feed([
            created, ev(2, 1, .turnStarted), plan(3, [("Add rows", "in_progress"), ("Wire it", "pending")]),
            activity(4, "tool", ["name": "Read", "summary": "a.swift"]),
            plan(5, [("Add rows", "done"), ("Wire it", "in_progress")]),
        ])
        let plans = items.filter { if case .plan = $0.kind { true } else { false } }
        #expect(plans.count == 1 && plans[0].seq == 3)
        #expect(
            plans[0].kind == .plan(tasks: [.init(text: "Add rows", state: .done), .init(text: "Wire it", state: .working)]),
            "the list as the turn left it")
    }

    @Test func aLogWithoutATaskListHasNoPlanRow() {
        let items = feed([created, ev(2, 1, .turnStarted), activity(3, "tool", ["name": "Read", "summary": "a"])])
        #expect(!items.contains { if case .plan = $0.kind { true } else { false } })
    }

    @Test func aDamagedTaskListIsLeftOut() {
        let items = feed([
            created, ev(2, 1, .turnStarted),
            activity(3, "plan", ["items": .array([.object(["text": "", "status": "done"]), .object(["status": "done"])])]),
            activity(4, "plan", ["items": "not a list"]),
        ])
        #expect(!items.contains { if case .plan = $0.kind { true } else { false } })
    }

    @Test func aLongRunOfCallsKeepsItsLatestThreeBesideTheFirstThree() {
        var events = [created, ev(2, 1, .turnStarted)]
        for n in 1...10 { events.append(activity(2 + n, "tool", ["name": "Read", "summary": .string("f\(n).swift")])) }
        let items = feed(events)
        let group = items.first { if case .toolGroup = $0.kind { true } else { false } }
        guard case .toolGroup(let count, let first)? = group?.kind else {
            Issue.record("no group")
            return
        }
        #expect(count == 10 && first == ["Read f1.swift", "Read f2.swift", "Read f3.swift"])
        let turn = items.first { if case .turn = $0.kind { true } else { false } }
        #expect(turn?.latest == ["Read f8.swift", "Read f9.swift", "Read f10.swift"], "what is happening now")
    }

    @Test func aRepeatedEditIsStillTheLatestCallEvenThoughItsRowIsShownOnce() {
        let events = [
            created, ev(2, 1, .turnStarted), activity(3, "tool", ["name": "Edit", "summary": "a.swift"]),
            activity(4, "tool", ["name": "Bash", "summary": "swift test"]),
            activity(5, "tool", ["name": "Edit", "summary": "a.swift"]),
        ]
        let items = feed(events)
        #expect(items.filter { if case .edit = $0.kind { true } else { false } }.count == 1, "one row for the file")
        let turn = items.first { if case .turn = $0.kind { true } else { false } }
        #expect(turn?.latest == ["Edit a.swift", "Bash swift test", "Edit a.swift"])
    }

    @Test func anEmptyTaskListClearsTheOneBefore() {
        let items = feed([
            created, ev(2, 1, .turnStarted), plan(3, [("Add rows", "in_progress")]),
            activity(4, "plan", ["items": .array([])]),
        ])
        #expect(!items.contains { if case .plan = $0.kind { true } else { false } }, "the agent dropped its tasks")
    }

    @Test func aJudgeThatDisagreesIsARowNotAHiddenOne() {
        let judged = ev(4, 1, .judgeRan, ["ok": true, "criteria": [["met": true], ["met": false]], "concerns": ["x"]])
        let items = feed([created, ev(2, 1, .turnStarted), ev(3, 1, .turnEnded, ["result": "succeeded"]), judged])
        #expect(items.contains { $0.kind == .judge(ok: true, criteria: 2, unmet: 1, concerns: 1) })
    }
}
