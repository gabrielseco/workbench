import Foundation
import Testing

@testable import WorkbenchCore

/// A thread whose turn 1 has a transcript file (the log holds only its result line) and whose turn 2 is an older
/// turn, with its `claude` events in the log.
private func mixedThread() async throws -> URL {
    let project = Project(root: Scratch.url("mixed"))
    let id = "g-mixed"
    let events = project.eventsURL(id)
    let log = try EventLogWriter.open(at: events)
    try await log.append(.threadCreated)
    try await log.append(.turnStarted, turn: 1)
    let writer = TranscriptWriter(url: TranscriptFile.url(in: project.threadDirectory(id), turn: 1))
    try writer.append(#"{"type":"system","subtype":"init"}"#)
    try writer.append(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#)
    let result = #"{"type":"result","subtype":"success","total_cost_usd":0.01,"permission_denials":[]}"#
    try writer.append(result)
    writer.close()
    try await log.appendClaudeLine(result, turn: 1)
    try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded", "transcript": ["lines": 3, "bytes": 1]])
    try await log.append(.turnStarted, turn: 2)
    try await log.appendClaudeLine(#"{"type":"system","subtype":"init"}"#, turn: 2)
    try await log.append(.turnEnded, turn: 2, data: ["result": "succeeded"])
    await log.close()
    return events
}

@Suite struct ThreadLogTranscriptTests {
    @Test func aTurnsLinesComeJustBeforeItsEndAndItsResultLineIsNotShownTwice() async throws {
        let url = try await mixedThread()
        let entries = try ThreadLog.read(at: url).entries
        let shape = entries.map { entry -> String in
            switch entry {
            case .event(let event): event.kind.rawValue + ":t\(event.turn)"
            case .transcript(let line): "line:t\(line.turn)" + (line.seq == nil ? ":file" : ":log")
            }
        }
        #expect(shape == [
            "thread.created:t0", "turn.started:t1",
            "line:t1:file", "line:t1:file", "line:t1:file", "turn.ended:t1",
            "turn.started:t2", "line:t2:log", "turn.ended:t2",
        ])
    }

    @Test func followingGivesEachSourceOnlyWhatIsNewAndTheLinesBeforeTheEnd() async throws {
        let project = Project(root: Scratch.url("follow"))
        let id = "g-follow"
        let log = try EventLogWriter.open(at: project.eventsURL(id))
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        let writer = TranscriptWriter(url: TranscriptFile.url(in: project.threadDirectory(id), turn: 1))
        try writer.append(#"{"type":"system","subtype":"init"}"#)

        var position = ThreadLog.Position()
        var seen: [String] = []
        func poll() throws {
            let (entries, next) = try ThreadLog.read(at: project.eventsURL(id)).entries(after: position)
            position = next
            seen += entries.map { entry in
                switch entry {
                case .event(let event): event.kind.rawValue
                case .transcript(let line): line.data["type"]?.stringValue ?? "?"
                }
            }
        }
        try poll()
        #expect(seen == ["thread.created", "turn.started", "system"])
        try poll()
        #expect(seen.count == 3, "nothing new, nothing repeated")

        try writer.append(#"{"type":"assistant"}"#)
        try writer.append(#"{"type":"user"}"#)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        try writer.append(#"{"type":"late"}"#)
        try poll()
        // Lines written before the end are shown before it, whichever file the reader looked at first.
        #expect(seen.suffix(4) == ["assistant", "user", "late", "turn.ended"])
        await log.close()
    }

    @Test func jsonLinesAreTheStoredEventsAndTheTranscriptAsClaudeEvents() async throws {
        let url = try await mixedThread()
        let threadLog = try ThreadLog.read(at: url)
        let (lines, _) = threadLog.jsonLines(after: ThreadLog.Position())
        let objects = try lines.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        #expect(objects.map { $0["kind"]?.stringValue ?? "?" } == [
            "thread.created", "turn.started", "claude", "claude", "claude", "turn.ended", "turn.started", "claude",
            "turn.ended",
        ])
        #expect(objects[2]["seq"] == .null && objects[2]["turn"]?.intValue == 1)
        #expect(objects[3]["data"]?["message"]?["content"] != nil)
        #expect(lines[2].hasSuffix(#""data":{"type":"system","subtype":"init"}}"#), "data is verbatim")
        // The stored events are their lines, byte for byte.
        let stored = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines[0] == stored[0] && lines[1] == stored[1])
        #expect(lines[7] == stored.first { $0.contains("\"turn\":2") && $0.contains("\"claude\"") })
    }

    @Test func anOpenTurnsLinesDriveItsProgress() async throws {
        let project = Project(root: Scratch.url("progress"))
        let id = "g-progress"
        let log = try EventLogWriter.open(at: project.eventsURL(id))
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        await log.close()
        let writer = TranscriptWriter(url: TranscriptFile.url(in: project.threadDirectory(id), turn: 1))
        for _ in 0..<2 {
            try writer.append(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#)
        }
        writer.close()

        let state = ThreadStore(project: project).state(of: id)
        #expect(state.openTurn == 1)
        #expect(state.progress.toolCalls == 2 && state.progress.toolCallsKnown)
        #expect(state.progress.lastEvent?.hasPrefix("tool_use Read") == true)
    }
}
