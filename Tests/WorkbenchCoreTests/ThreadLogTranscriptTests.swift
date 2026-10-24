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
            case .unreadableTranscript(let turn, _): "unreadable:t\(turn)"
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
                case .unreadableTranscript: "unreadable"
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

    @Test func aLogWithALineThatIsNotAnEventStillFollowsItsTranscriptWithoutRepeats() async throws {
        let project = Project(root: Scratch.url("fallback"))
        let id = "g-fallback"
        let log = try EventLogWriter.open(at: project.eventsURL(id))
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        await log.close()
        // A whole line that is not an event: the raw lines and the events no longer line up.
        let handle = try FileHandle(forWritingTo: project.eventsURL(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not an event\n".utf8))
        try handle.close()
        let writer = TranscriptWriter(url: TranscriptFile.url(in: project.threadDirectory(id), turn: 1))
        try writer.append(#"{"type":"system"}"#)

        let first = try ThreadLog.read(at: project.eventsURL(id)).entries(after: ThreadLog.Position())
        #expect(first.entries.contains { if case .transcript = $0 { true } else { false } })
        try writer.append(#"{"type":"assistant"}"#)
        let second = try ThreadLog.read(at: project.eventsURL(id)).entries(after: first.position)
        #expect(second.entries.count == 1, "only the new line, not the first again")
        // `--json` prints the stored lines as they are here, once, and a later poll gives only what was added.
        let json = try ThreadLog.read(at: project.eventsURL(id)).jsonLines(after: ThreadLog.Position())
        #expect(json.lines.count == 3 && json.lines.last == "not an event")
        let again = try ThreadLog.read(at: project.eventsURL(id)).jsonLines(after: json.position)
        #expect(again.lines.isEmpty && again.position == json.position)
    }
}

@Suite struct UnreadableTranscriptTests {
    /// Turn 1 has a gzipped transcript that was then damaged; the log still holds its result line.
    private func damaged() async throws -> URL {
        let url = try await mixedThreadForDamage()
        let file = TranscriptFile.url(in: url.deletingLastPathComponent(), turn: 1)
        #expect(TranscriptFile.compress(file))
        var packed = try Data(contentsOf: TranscriptFile.compressedURL(file))
        packed[packed.count / 2] ^= 0xFF
        try packed.write(to: TranscriptFile.compressedURL(file))
        return url
    }

    private func mixedThreadForDamage() async throws -> URL {
        let directory = Scratch.url("damaged")
        let url = directory.appendingPathComponent("events.jsonl")
        let log = try EventLogWriter.open(at: url)
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        let writer = TranscriptWriter(url: TranscriptFile.url(in: directory, turn: 1))
        for n in 0..<50 { try writer.append(#"{"type":"assistant","n":\#(n)}"#) }
        let result = #"{"type":"result","subtype":"success","permission_denials":[]}"#
        try writer.append(result)
        writer.close()
        try await log.appendClaudeLine(result, turn: 1)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        await log.close()
        return url
    }

    @Test func aDamagedTranscriptIsSaidAndTheLogsResultLineIsStillShown() async throws {
        let url = try await damaged()
        let entries = try ThreadLog.read(at: url).entries
        let shape = entries.map { entry -> String in
            switch entry {
            case .event(let event): event.kind.rawValue
            case .transcript(let line): "line:t\(line.turn)"
            case .unreadableTranscript(let turn, _): "unreadable:t\(turn)"
            }
        }
        // The log's own copy of the result line stays (it is the one a stored line, with a seq), then the note.
        #expect(shape == ["thread.created", "turn.started", "line:t1", "unreadable:t1", "turn.ended"], "\(shape)")
        let kept = entries.compactMap { entry -> TranscriptLine? in
            if case .transcript(let line) = entry { line } else { nil }
        }
        #expect(kept.count == 1 && kept[0].seq != nil && kept[0].data["type"] == "result")
        let entry = try #require(entries.first { if case .unreadableTranscript = $0 { true } else { false } })
        let said = LogFormatter.describe(entry)
        #expect(said.contains("t1  transcript cannot be read: damaged"), Comment(rawValue: said))
    }

    @Test func followingSaysItOnceAndJSONNamesIt() async throws {
        let url = try await damaged()
        let threadLog = try ThreadLog.read(at: url)
        let first = threadLog.entries(after: ThreadLog.Position())
        let again = threadLog.entries(after: first.position)
        #expect(again.entries.isEmpty)
        let (lines, _) = threadLog.jsonLines(after: ThreadLog.Position())
        #expect(lines.contains { $0.contains("\"kind\":\"transcript.unreadable\"") && $0.contains("\"turn\":1") })
        #expect(lines.contains { $0.contains("\"kind\":\"claude\"") }, "the log's own result line is still there")
    }

    @Test func logTranscriptFailsRatherThanPrintingNothing() async throws {
        let url = try await damaged()
        #expect(throws: ThreadLogError.self) { try ThreadLog.read(at: url).transcript() }
        do { _ = try ThreadLog.read(at: url).transcript(turn: 1) } catch let error as ThreadLogError {
            #expect("\(error)".hasPrefix("the transcript of turn 1 cannot be read: damaged"))
        }
        // A turn that is not damaged is still printed.
        #expect(try ThreadLog.read(at: url).transcript(turn: 2).isEmpty)
    }
}
