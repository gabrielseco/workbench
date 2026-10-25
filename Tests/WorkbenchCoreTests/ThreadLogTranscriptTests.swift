import Foundation
import Testing

@testable import WorkbenchCore

/// A turn as every provider records it: its `agent.activity` in the log, the raw lines in the transcript file.
private func thread(_ name: String, provider: String = "claude") async throws -> (project: Project, id: String) {
    let project = Project(root: Scratch.url(name))
    let id = "g-\(name)"
    let log = try EventLogWriter.open(at: project.eventsURL(id))
    try await log.append(.threadCreated)
    try await log.append(.turnStarted, turn: 1, data: ["provider": .string(provider)])
    try await log.append(
        .agentActivity, turn: 1,
        data: ["provider": .string(provider), "type": "tool", "name": "shell", "summary": "ls"])
    let writer = TranscriptWriter(url: TranscriptFile.url(in: project.threadDirectory(id), turn: 1))
    try writer.append(#"{"type":"item.started","item":{"type":"command_execution","command":"ls"}}"#)
    try writer.append(#"{"type":"result","subtype":"success"}"#)
    writer.close()
    try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
    await log.close()
    return (project, id)
}

@Suite struct ThreadLogTranscriptTests {
    @Test func logIsTheEventsAndTheTranscriptIsOnlyWhatTranscriptReturns() async throws {
        for provider in ["claude", "codex"] {
            let (project, id) = try await thread("kinds-\(provider)", provider: provider)
            let read = try ThreadLog.read(at: project.eventsURL(id))
            #expect(read.entries.map(\.kind.rawValue) == ["thread.created", "turn.started", "agent.activity", "turn.ended"])
            #expect(try read.transcript(turn: 1) == [
                #"{"type":"item.started","item":{"type":"command_execution","command":"ls"}}"#,
                #"{"type":"result","subtype":"success"}"#,
            ])
            #expect(try read.transcript(turn: 2).isEmpty, "a turn with no file has no lines")
        }
    }

    @Test func followingGivesOnlyTheEventsThatAreNew() async throws {
        let project = Project(root: Scratch.url("follow"))
        let id = "g-follow"
        let log = try EventLogWriter.open(at: project.eventsURL(id))
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)

        let first = try ThreadLog.read(at: project.eventsURL(id)).entries(after: ThreadLog.Position())
        #expect(first.entries.map(\.kind.rawValue) == ["thread.created", "turn.started"])
        let nothing = try ThreadLog.read(at: project.eventsURL(id)).entries(after: first.position)
        #expect(nothing.entries.isEmpty && nothing.position == first.position, "nothing new, nothing repeated")

        try await log.append(.agentActivity, turn: 1, data: ["provider": "claude", "type": "text", "text": "hi"])
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        let more = try ThreadLog.read(at: project.eventsURL(id)).entries(after: first.position)
        #expect(more.entries.map(\.kind.rawValue) == ["agent.activity", "turn.ended"])
        await log.close()
    }

    @Test func jsonLinesAreTheStoredLinesOnceEvenWithALineThatIsNotAnEvent() async throws {
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

        let stored = try String(contentsOf: project.eventsURL(id), encoding: .utf8).split(separator: "\n").map(String.init)
        let json = try ThreadLog.read(at: project.eventsURL(id)).jsonLines(after: ThreadLog.Position())
        #expect(json.lines == stored && json.lines.last == "not an event")
        let again = try ThreadLog.read(at: project.eventsURL(id)).jsonLines(after: json.position)
        #expect(again.lines.isEmpty && again.position == json.position)
    }

    @Test func anOpenClaudeTurnsProgressIsItsActivityNotItsFile() async throws {
        let project = Project(root: Scratch.url("progress"))
        let id = "g-progress"
        let log = try EventLogWriter.open(at: project.eventsURL(id))
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1, data: ["provider": "claude"])
        for _ in 0..<2 {
            try await log.append(
                .agentActivity, turn: 1, data: ["provider": "claude", "type": "tool", "name": "Read", "summary": "a.swift"])
        }
        await log.close()
        let writer = TranscriptWriter(url: TranscriptFile.url(in: project.threadDirectory(id), turn: 1))
        for _ in 0..<2 {
            try writer.append(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#)
        }
        writer.close()

        let state = ThreadStore(project: project).state(of: id)
        #expect(state.openTurn == 1)
        #expect(state.progress.toolCalls == 2 && state.progress.toolCallsKnown, "the file is not counted again")
        #expect(state.progress.lastEvent == "tool_use Read a.swift")
    }
}

@Suite struct UnreadableTranscriptTests {
    /// Turn 1 has a gzipped transcript that was then damaged.
    private func damaged() async throws -> URL {
        let (project, id) = try await thread("damaged")
        let file = TranscriptFile.url(in: project.threadDirectory(id), turn: 1)
        #expect(TranscriptFile.compress(file))
        var packed = try Data(contentsOf: TranscriptFile.compressedURL(file))
        packed[packed.count / 2] ^= 0xFF
        try packed.write(to: TranscriptFile.compressedURL(file))
        return project.eventsURL(id)
    }

    @Test func aDamagedFileDoesNotTouchWhatTheLogShows() async throws {
        let url = try await damaged()
        let read = try ThreadLog.read(at: url)
        #expect(read.entries.map(\.kind.rawValue) == ["thread.created", "turn.started", "agent.activity", "turn.ended"])
        let (lines, _) = read.jsonLines(after: ThreadLog.Position())
        #expect(lines.count == 4)
    }

    @Test func logTranscriptFailsRatherThanPrintingNothing() async throws {
        let url = try await damaged()
        #expect(throws: ThreadLogError.self) { try ThreadLog.read(at: url).transcript() }
        do {
            _ = try ThreadLog.read(at: url).transcript(turn: 1)
            Issue.record("a damaged file was printed as nothing")
        } catch let error as ThreadLogError {
            #expect("\(error)".hasPrefix("the transcript of turn 1 cannot be read: damaged"))
        }
        // A turn that is not damaged is still printed.
        #expect(try ThreadLog.read(at: url).transcript(turn: 2).isEmpty)
    }
}
