import Foundation
import Testing

@testable import WorkbenchCore

/// The feed is a function of the log: a fixture log in, the items a screen draws out, in order and bounded.
@Suite struct FeedTests {
    private func ev(_ seq: Int, _ turn: Int, _ kind: EventKind, _ data: JSONValue = [:]) -> Event {
        Event(seq: seq, ts: "2026-11-02T10:00:\(String(format: "%02d", seq % 60)).000Z", turn: turn, kind: kind, data: data)
    }

    private func activity(_ seq: Int, _ type: String, _ fields: [String: JSONValue] = [:]) -> Event {
        var data = fields
        data["type"] = .string(type)
        data["provider"] = "claude"
        return ev(seq, 1, .agentActivity, .object(data))
    }

    private func contents(_ events: [Event], extra: Data = Data()) -> EventLogContents {
        let encoder = JSONEncoder()
        var data = Data()
        for event in events {
            data.append(try! encoder.encode(event))
            data.append(UInt8(ascii: "\n"))
        }
        data.append(extra)
        return EventLogReader.parse(data)
    }

    private func feed(
        _ events: [Event], goal: Feed.GoalSummary? = nil, approval: ApprovalState? = nil, runnerAlive: Bool = true,
        extra: Data = Data()
    ) -> [FeedItem] {
        let read = contents(events, extra: extra)
        let state = ThreadState.derive(from: read.events, id: "t")
        let spine = ThreadSpine.derive(state: state, approval: approval)
        return Feed.items(
            contents: read, goal: goal, state: state, spine: spine,
            attention: Attention.derive(spine: spine, state: state), runnerAlive: runnerAlive)
    }

    private func kinds(_ items: [FeedItem]) -> [FeedItem.Kind] { items.map(\.kind) }

    private let created = Event(seq: 1, ts: "2026-11-02T10:00:01.000Z", turn: 0, kind: .threadCreated, data: ["base": "main"])

    // MARK: One test per kind

    @Test func aNoteSentBackIsAUserMessage() {
        let items = feed([created, ev(2, 0, .threadNote, ["text": "please\nretry the second file"])])
        #expect(items.contains { $0.kind == .userNote(text: "please retry the second file") && $0.seq == 2 })
    }

    @Test func theGoalIsOneCardAtItsFirstEventAndSaysWhenItIsStale() {
        let goal = Feed.GoalSummary(title: "Add retry", approval: .stale, criteria: 2)
        let items = feed(
            [
                created, ev(2, 0, .goalSaved, ["hash": "a"]), ev(3, 0, .goalApproved, ["hash": "a"]),
                ev(4, 0, .threadNote, ["text": "x"]),
            ],
            goal: goal, approval: .stale)
        let cards = items.filter { if case .goalCard = $0.kind { true } else { false } }
        #expect(cards.count == 1 && cards[0].kind == .goalCard(title: "Add retry", approval: .stale, criteria: 2, hash: "a"))
        let order = items.map(\.id)
        #expect(order.firstIndex(of: "goal")! < order.firstIndex(of: "4")!, "before what happened after it")
        #expect(items.contains { $0.kind == .notice(.goalChangedSinceApproval) })
    }

    @Test func aTurnIsOneItemWithHowItEnded() {
        let items = feed([
            created, ev(2, 1, .turnStarted),
            ev(3, 1, .turnEnded, ["result": "succeeded", "duration_ms": 90_000, "cost_usd": 1.5]),
        ])
        let ended = FeedItem.Kind.turn(number: 1, phase: .ended(result: "succeeded"), durationMs: 90_000, costUSD: 1.5)
        #expect(items.contains { $0.kind == ended })
    }

    @Test func textToolsEditsAndRefusalsAreItemsAndConsecutiveToolsGroup() {
        let items = feed([
            created, ev(2, 1, .turnStarted),
            activity(3, "text", ["text": "Reading the client."]),
            activity(4, "tool", ["name": "Read", "summary": "a.swift"]),
            activity(5, "tool", ["name": "Grep", "summary": "retry"]),
            activity(6, "tool", ["name": "Edit", "summary": "Sources/Client.swift"]),
            activity(7, "tool", ["name": "Edit", "summary": "Sources/Client.swift"]),
            activity(8, "permission_denied", ["tool": "Bash"]),
            ev(9, 1, .turnEnded, ["result": "succeeded"]),
        ])
        let body = kinds(items).filter { if case .turn = $0 { false } else { true } }
        #expect(
            Array(body.prefix(4)) == [
                .agentText("Reading the client."), .toolGroup(count: 2, summaries: ["Read a.swift", "Grep retry"]),
                .edit(file: "Sources/Client.swift", tool: "Edit"), .denied(tool: "Bash", input: nil),
            ], "the second edit of a file is the same row")
    }

    @Test func aCheckAJudgeAndAVerifyAreItems() {
        let items = feed([
            created, ev(2, 1, .turnStarted), ev(3, 1, .turnEnded, ["result": "succeeded"]),
            ev(4, 1, .checkRan, ["command": "swift test", "result": "passed", "duration_ms": 5000]),
            ev(
                5, 1, .judgeRan,
                ["ok": true, "criteria": [["id": "c1", "met": true], ["id": "c2", "met": false]], "concerns": ["x"]]),
            ev(6, 1, .verifierEnded, ["ok": true, "files": [["name": "shot.png", "bytes": 1, "sha256": "h"]]]),
        ])
        #expect(items.contains { $0.kind == .check(result: "passed", command: "swift test", durationMs: 5000) })
        #expect(items.contains { $0.kind == .judge(ok: true, criteria: 2, unmet: 1, concerns: 1) })
        #expect(items.contains { $0.kind == .verify(ok: true, reason: nil, proofs: ["shot.png"]) })
    }

    @Test func aJudgeThatFailedHasNoCriteria() {
        let items = feed([created, ev(2, 1, .judgeRan, ["ok": false, "reason": "no answer"])])
        #expect(items.contains { $0.kind == .judge(ok: false, criteria: 0, unmet: 0, concerns: 0) })
    }

    @Test func aDecisionAPullRequestAndAPRReviewAreItems() {
        let items = feed([
            created, ev(2, 1, .reviewDecision, ["decision": "accepted"]),
            ev(3, 1, .prOpened, ["number": 7, "url": "https://example.test/pull/7"]),
            ev(4, 1, .prReviewFinished, ["round": 1, "verdict": "findings", "ok": true]),
        ])
        #expect(items.contains { $0.kind == .decision("accepted") })
        #expect(items.contains { $0.kind == .pullRequest(number: 7, url: "https://example.test/pull/7") })
        #expect(items.contains { $0.kind == .prReview(round: 1, verdict: "findings", ok: true) })
    }

    @Test func theNextStepComesFromTheSpineAndAttention() {
        let items = feed([created, ev(2, 1, .turnStarted), ev(3, 1, .turnEnded, ["result": "succeeded"])], approval: .approved)
        guard case .next(let step, let why)? = items.last?.kind else { Issue.record("no next card"); return }
        #expect(step == .review && !why.isEmpty)
    }

    @Test func aDraftsNextStepIsTheGoal() {
        let items = feed([created], goal: Feed.GoalSummary(title: "t", approval: .draft, criteria: 0), approval: .draft)
        guard case .next(let step, _)? = items.last?.kind else { Issue.record("no next card"); return }
        #expect(step == .goal)
    }

    // MARK: Order, ends, bounds

    @Test func itemsKeepLogOrderAndSayWhichEventTheyCameFrom() {
        let items = feed([
            created, ev(2, 0, .threadNote, ["text": "a"]), ev(3, 1, .turnStarted), activity(4, "text", ["text": "b"]),
            ev(5, 1, .turnEnded, ["result": "succeeded"]), ev(6, 1, .checkRan, ["result": "passed"]),
        ])
        let seqs = items.map(\.seq).filter { $0 > 0 }
        #expect(seqs == seqs.sorted() && Set(items.map(\.id)).count == items.count, "in order, ids unique")
    }

    @Test func aTurnThatNeverEndedIsNeverShownAsEnded() {
        let open = feed([created, ev(2, 1, .turnStarted)])
        #expect(open.contains { if case .turn(_, .working, _, _) = $0.kind { true } else { false } })
        let dead = feed([created, ev(2, 1, .turnStarted)], runnerAlive: false)
        #expect(dead.contains { if case .turn(_, .orphaned, _, _) = $0.kind { true } else { false } })
        let broken = feed([created, ev(2, 1, .turnStarted), ev(3, 2, .turnStarted)])
        #expect(
            broken.contains { if case .turn(1, .unrecorded, _, _) = $0.kind { true } else { false } },
            "turn 1 never ended and is not the open one")
    }

    @Test func aThousandActivityEventsAreAtMostSixtyItemsForTheTurn() {
        var events = [created, ev(2, 1, .turnStarted)]
        for n in 0..<1_000 {
            let seq = 3 + n
            switch n % 3 {
            case 0: events.append(activity(seq, "text", ["text": .string("step \(n)")]))
            case 1: events.append(activity(seq, "tool", ["name": "Edit", "summary": .string("file\(n).swift")]))
            default: events.append(activity(seq, "permission_denied", ["tool": n == 5 ? "Bash" : "Read"]))
            }
        }
        events.append(ev(1_003, 1, .turnEnded, ["result": "succeeded"]))
        let items = feed(events)
        let turn = items.filter { $0.turn == 1 }
        #expect(turn.count <= 60, "got \(turn.count)")
        #expect(turn.contains { if case .notice(.activityFolded(let count, _)) = $0.kind { count > 900 } else { false } })
        #expect(items.last.map { if case .next = $0.kind { true } else { false } } == true)
    }

    @Test func twentyThousandEventsStayBounded() {
        var events = [created, ev(2, 1, .turnStarted)]
        for n in 0..<20_000 { events.append(activity(3 + n, "tool", ["name": "Edit", "summary": .string("f\(n)")])) }
        let items = feed(events)
        #expect(items.count <= Feed.maxActivityPerTurn + 10)
    }

    @Test func manyTurnsKeepTheNewestAndSayHowManyAreNotShown() {
        var events = [created]
        var seq = 2
        for turn in 1...700 {
            events.append(ev(seq, turn, .turnStarted))
            events.append(ev(seq + 1, turn, .turnEnded, ["result": "succeeded"]))
            events.append(ev(seq + 2, turn, .checkRan, ["result": "passed"]))
            seq += 3
        }
        let items = feed(events)
        #expect(items.count <= Feed.maxItems)
        guard case .notice(.earlierNotShown(let count)) = items.first(where: { $0.id == "earlier" })?.kind ?? .decision("") else {
            Issue.record("no notice")
            return
        }
        #expect(count > 0)
        #expect(items.contains { if case .turn(700, _, _, _) = $0.kind { true } else { false } })
    }

    @Test func aTurnsRefusedCallsSurviveFolding() {
        var events = [created, ev(2, 1, .turnStarted)]
        for n in 0..<200 { events.append(activity(3 + n, "text", ["text": .string("t\(n)")])) }
        events.append(activity(203, "permission_denied", ["tool": "Bash"]))
        for n in 0..<200 { events.append(activity(204 + n, "text", ["text": .string("u\(n)")])) }
        let items = feed(events)
        #expect(items.contains { $0.kind == .denied(tool: "Bash", input: nil) })
    }

    // MARK: Damage, untrusted text, old logs

    @Test func aDamagedLogShowsWhatItCouldReadAndSaysSo() {
        var data = Data()
        let encoder = JSONEncoder()
        for event in [created, ev(2, 0, .threadNote, ["text": "kept"])] {
            data.append(try! encoder.encode(event))
            data.append(UInt8(ascii: "\n"))
        }
        data.append(Data("{not json}\n".utf8))
        let read = EventLogReader.parse(data)
        let state = ThreadState.derive(from: read.events, id: "t")
        let items = Feed.items(contents: read, goal: nil, state: state, spine: ThreadSpine.derive(state: state))
        #expect(items.contains { $0.kind == .userNote(text: "kept") })
        guard case .notice(.logDamaged(let problems, _))? = items.first?.kind else {
            Issue.record("no damage notice first")
            return
        }
        #expect(problems == 1)
    }

    @Test func aSeqGapIsDamageToo() {
        let items = feed([created, ev(5, 0, .threadNote, ["text": "after a gap"])])
        #expect(items.first.map { if case .notice(.logDamaged) = $0.kind { true } else { false } } == true)
        #expect(items.contains { $0.kind == .userNote(text: "after a gap") })
    }

    @Test func aCutLastLineIsNotedAsACrashNotADamage() {
        let items = feed([created], extra: Data("{\"v\":1,\"seq\":2".utf8))
        #expect(items.first?.kind == .notice(.logTailCut))
    }

    @Test func untrustedTextIsOneBoundedLineAndNeverInterpreted() {
        let huge = String(repeating: "x", count: 1_000_000) + "\u{1B}[31mred\u{07}\nline"
        let items = feed([
            created, ev(2, 0, .threadNote, ["text": .string(huge)]), ev(3, 1, .turnStarted),
            activity(4, "text", ["text": .string(huge)]),
        ])
        for item in items {
            switch item.kind {
            case .userNote(let text): #expect(text.count <= Feed.noteLimit && !text.contains("\u{1B}") && !text.contains("\n"))
            case .agentText(let text): #expect(text.count <= Feed.textLimit && !text.contains("\u{1B}") && !text.contains("\n"))
            default: break
            }
        }
    }

    @Test func unknownKindsAndFieldsAreIgnoredAndAThreadWithNoTurnsIsShort() {
        let items = feed([created, ev(2, 0, "future.kind", ["x": 1]), ev(3, 0, .threadNote, ["text": "hi", "extra": true])])
        #expect(items.count == 2, "the note and the next-step card; the unknown kind is not a row")
        #expect(items.contains { $0.kind == .userNote(text: "hi") })
    }

    @Test func afterAFailedTurnTheNextStepIsReviewNotTheRunThatFailed() {
        let items = feed(
            [created, ev(2, 1, .turnStarted), ev(3, 1, .turnEnded, ["result": "failed"])], approval: .approved)
        guard case .next(let step, let why)? = items.last?.kind else {
            Issue.record("no next card")
            return
        }
        #expect(step == .review && !why.isEmpty, "got \(String(describing: step)): \(why)")
    }

    @Test func twoRefusedCallsWithDifferentInputsAreToldApart() {
        let denials: JSONValue = [["tool": "Bash", "input": "git push origin main"], ["tool": "Bash", "input": "rm -rf build"]]
        let items = feed([
            created, ev(2, 1, .turnStarted), activity(3, "permission_denied", ["tool": "Bash"]),
            activity(4, "permission_denied", ["tool": "Bash"]), ev(5, 1, .turnEnded, ["result": "succeeded", "denials": denials]),
        ])
        let refused = items.compactMap { item -> String? in
            if case .denied(_, let input) = item.kind { input } else { nil }
        }
        #expect(refused == ["git push origin main", "rm -rf build"])
    }

    @Test func aRefusalCarriesItsCommandWhileTheTurnIsStillRunning() {
        let items = feed([
            created, ev(2, 1, .turnStarted), activity(3, "permission_denied", ["tool": "Bash", "input": "git push origin main"]),
        ])
        #expect(items.contains { $0.kind == .denied(tool: "Bash", input: "git push origin main") })
    }

    @Test func aRefusalWhoseInputWasNotRecordedHasNone() {
        let items = feed([
            created, ev(2, 1, .turnStarted), activity(3, "permission_denied", ["tool": "Bash"]),
            ev(4, 1, .turnEnded, ["result": "succeeded"]),
        ])
        #expect(items.contains { $0.kind == .denied(tool: "Bash", input: nil) })
    }

    @Test func theGoalCardNamesTheApprovedRevision() {
        let goal = Feed.GoalSummary(title: "t", approval: .approved, criteria: 1)
        let items = feed(
            [
                created, ev(2, 0, .goalSaved, ["hash": "first"]), ev(3, 0, .goalSaved, ["hash": "second"]),
                ev(4, 0, .goalApproved, ["hash": "approved"]),
            ],
            goal: goal, approval: .approved)
        #expect(items.contains { $0.kind == .goalCard(title: "t", approval: .approved, criteria: 1, hash: "approved") })
    }

    @Test func aThreadWithOnlyAGoalHasTheGoalCardAndWhatToDoNext() {
        let goal = Feed.GoalSummary(title: "t", approval: .draft, criteria: 0)
        let items = feed([created, ev(2, 0, .goalSaved, ["hash": "h"])], goal: goal, approval: .draft)
        #expect(items.map(\.id) == ["goal", "next"])
    }

    @Test func refusalsPastTheCapAreCountedNotLost() {
        var events = [created, ev(2, 1, .turnStarted)]
        for n in 0..<100 { events.append(activity(3 + n, "permission_denied", ["tool": "Bash"])) }
        let items = feed(events)
        let kept = items.filter { if case .denied = $0.kind { true } else { false } }.count
        #expect(kept == Feed.maxActivityPerTurn - 1)
        let notice = items.compactMap { item -> Int? in
            if case .notice(.activityFolded(_, let refusals)) = item.kind { refusals } else { nil }
        }
        #expect(notice == [100 - kept], "the rest are said to be refusals, not silently dropped")
    }

    @Test func controlCharactersInsideTheLimitAreRemoved() {
        let text = "before\u{1B}[31mred\u{07}after\nnext"
        let items = feed([created, ev(2, 0, .threadNote, ["text": .string(text)])])
        #expect(items.contains { $0.kind == .userNote(text: "beforeredafter next") })
    }

    @Test func aDiscardedThreadHasNothingLeftEvenAfterAFailedRun() {
        let items = feed([
            created, ev(2, 1, .turnStarted), ev(3, 1, .turnEnded, ["result": "failed"]),
            ev(4, 1, .reviewDecision, ["decision": "discarded"]),
        ], approval: .approved)
        guard case .next(let step, _)? = items.last?.kind else {
            Issue.record("no next card")
            return
        }
        #expect(step == nil, "got \(String(describing: step))")
    }

    @Test func twoLongPathsThatShareTheirFirstCharactersAreTwoEdits() {
        let prefix = String(repeating: "a/", count: 100)
        let items = feed([
            created, ev(2, 1, .turnStarted), activity(3, "tool", ["name": "Edit", "summary": .string(prefix + "one.swift")]),
            activity(4, "tool", ["name": "Edit", "summary": .string(prefix + "two.swift")]),
        ])
        let edits = items.filter { if case .edit = $0.kind { true } else { false } }
        #expect(edits.count == 2)
    }

    @Test func aRefusalTheActivityRowsDidNotKeepIsStillShown() {
        let denials: JSONValue = [["tool": "Bash", "input": "git push"], ["tool": "Bash", "input": "rm -rf build"]]
        let items = feed([
            created, ev(2, 1, .turnStarted), activity(3, "permission_denied", ["tool": "Bash"]),
            ev(4, 1, .turnEnded, ["result": "succeeded", "denials": denials]),
        ])
        let refused = items.compactMap { item -> String? in
            if case .denied(_, let input) = item.kind { input } else { nil }
        }
        #expect(refused == ["git push", "rm -rf build"], "the second one came from turn.ended; no duplicate of the first")
    }
}
