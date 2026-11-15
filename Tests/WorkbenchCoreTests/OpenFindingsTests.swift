import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct OpenFindingsTests {
    private func event(_ seq: Int, _ kind: EventKind, turn: Int = 1, _ data: JSONValue) -> Event {
        Event(seq: seq, ts: "2026-10-01T10:00:0\(seq % 10).000Z", turn: turn, kind: kind, data: data)
    }

    private let criteria = [
        Criterion(id: "c1", text: "A works", proof: "test"), Criterion(id: "c2", text: "B works", proof: "test"),
    ]

    private func base(judge: JSONValue? = nil, stage: JSONValue? = nil, stageTurnOrder: Bool = true) -> [Event] {
        var events = [
            event(1, .threadCreated, turn: 0, ["repo": "/r", "base": "main", "worktree": "/w", "branch": "workbench/t"]),
            event(2, .turnStarted, ["session_id": "s", "resume": false]),
            event(3, .turnEnded, ["result": "succeeded", "exit_code": 0]),
        ]
        if let judge { events.append(event(4, .judgeRan, judge)) }
        if let stage { events.append(event(5, .reviewStageFinished, stage)) }
        return events
    }

    private func derive(_ events: [Event], dir: URL? = nil) -> OpenFindings {
        OpenFindings.derive(
            state: ThreadState.derive(from: events, id: "t"), criteria: criteria, events: events, threadDirectory: dir)
    }

    private let unmetJudge: JSONValue = [
        "ok": true,
        "criteria": [
            ["id": "c1", "met": true, "evidence": ["ok"]], ["id": "c2", "met": false, "evidence": ["no test covers it"]],
        ],
        "concerns": ["a rename is half done"],
    ]

    @Test func anUnmetCriterionAndAConcernAreListedWithTheirText() {
        let found = derive(base(judge: unmetJudge))
        #expect(found.items.map(\.id) == ["criterion:c2", "concern:0"])
        #expect(found.items[0].title == "[c2] not met: B works")
        #expect(found.items[0].detail == "no test covers it")
        #expect(found.summary == "Judge: 1 criterion not met, 1 concern")
    }

    @Test func aLongCriterionAndAllItsEvidenceAreKeptWhole() {
        let long = String(repeating: "word ", count: 60)
        let judge: JSONValue = [
            "ok": true, "criteria": [["id": "c2", "met": false, "evidence": ["first", "second"]]], "concerns": [],
        ]
        let events = base(judge: judge)
        let found = OpenFindings.derive(
            state: ThreadState.derive(from: events, id: "t"), criteria: [Criterion(id: "c2", text: long, proof: "test")],
            events: events, threadDirectory: nil)
        #expect(found.items[0].title == "[c2] not met: " + long.trimmingCharacters(in: .whitespaces))
        #expect(found.items[0].detail == "first\nsecond")
        #expect(found.feedback.contains(found.items[0].title + " (first second)"))
    }

    @Test func aJudgeThatMetEverythingLeavesNothing() {
        let judge: JSONValue = ["ok": true, "criteria": [["id": "c1", "met": true, "evidence": []]], "concerns": []]
        #expect(derive(base(judge: judge)).isEmpty)
    }

    @Test func aJudgeOfAnOlderTurnSaysNothingOfTheLatest() {
        var events = base(judge: unmetJudge)
        events.append(event(6, .turnStarted, turn: 2, ["session_id": "s", "resume": true]))
        events.append(event(7, .turnEnded, turn: 2, ["result": "succeeded", "exit_code": 0]))
        #expect(derive(events).isEmpty)
    }

    @Test func aStageWithFindingsIsReadFromItsFileInsideTheThread() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("of-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("design"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "- the button is 6pt off\n# not a heading".write(
            to: dir.appendingPathComponent("design/round-1.findings.md"), atomically: true, encoding: .utf8)
        let stage: JSONValue = [
            "stage": "design", "ok": true, "verdict": "findings", "findings_path": "design/round-1.findings.md",
        ]
        let found = derive(base(stage: stage), dir: dir)
        #expect(found.items.map(\.id) == ["stage:design"])
        #expect(found.summary == "Design: findings to fix")
        #expect(found.feedback.contains("> - the button is 6pt off"), "quoted, so its lines are data")
        #expect(found.feedback.contains("> # not a heading"))
    }

    @Test func aCleanOrFailedStageIsNotAFinding() {
        #expect(derive(base(stage: ["stage": "design", "ok": true, "verdict": "clean"])).isEmpty)
        #expect(derive(base(stage: ["stage": "design", "ok": false, "verdict": .null])).isEmpty)
    }

    @Test func aFindingsPathThatLeavesTheThreadIsNotRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("of-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for path in ["../secret.md", "/etc/hosts"] {
            let stage: JSONValue = ["stage": "design", "ok": true, "verdict": "findings", "findings_path": .string(path)]
            #expect(derive(base(stage: stage), dir: dir).items.first?.detail == nil, "\(path)")
        }
    }

    @Test func aSymlinkedFindingsFileOrFolderIsNotFollowedOutOfTheThread() throws {
        let outer = FileManager.default.temporaryDirectory.appendingPathComponent("of-\(UUID().uuidString)")
        let dir = outer.appendingPathComponent("thread")
        let secret = outer.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("design"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outer) }
        try "private".write(to: secret.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("design/file.md"), withDestinationURL: secret.appendingPathComponent("a.md"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("linked"), withDestinationURL: secret)
        for path in ["design/file.md", "linked/a.md"] {
            let stage: JSONValue = ["stage": "design", "ok": true, "verdict": "findings", "findings_path": .string(path)]
            #expect(derive(base(stage: stage), dir: dir).items.first?.detail == nil, "\(path)")
        }
    }

    @Test func aLongFindingsFileIsCutAtTheLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("of-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try String(repeating: "x", count: OpenFindings.stageTextLimit * 3).write(
            to: dir.appendingPathComponent("f.md"), atomically: true, encoding: .utf8)
        let stage: JSONValue = ["stage": "design", "ok": true, "verdict": "findings", "findings_path": "f.md"]
        let detail = derive(base(stage: stage), dir: dir).items.first?.detail
        #expect(detail?.hasSuffix("(cut)") == true && (detail?.count ?? 0) < OpenFindings.stageTextLimit + 20)
    }

    @Test func aStageThatRanBeforeTheLatestTurnIsStale() {
        var events = base()
        events.insert(event(2, .reviewStageFinished, ["stage": "design", "ok": true, "verdict": "findings"]), at: 2)
        #expect(derive(events).isEmpty, "the turn ended after the stage, so its findings are of older work")
    }
}
