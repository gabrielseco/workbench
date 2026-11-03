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

}
