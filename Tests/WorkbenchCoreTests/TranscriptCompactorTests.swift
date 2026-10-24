import Foundation
import Testing

@testable import WorkbenchCore

private let denialResult =
    #"{"type":"result","subtype":"success","total_cost_usd":0.5,"permission_denials":"#
    + #"[{"tool_name":"Bash","tool_input":{"command":"chmod +x a.sh"}}]}"#

/// A thread as an older Workbench wrote it: every stream line a `claude` event in the log. Turn 1 has an attempt, a
/// note before it, a denial, and a grant that names the denial's `seq`; turn 2 is plainer; the thread is accepted.
private struct Legacy {
    var project: Project
    var id: String
}

private func legacyThread(_ name: String = "legacy", extraLines: Int = 0) async throws -> Legacy {
    let project = Project(root: Scratch.url(name))
    let id = "g-\(name)"
    let log = try EventLogWriter.open(at: project.eventsURL(id))
    try await log.append(.threadCreated)
    try await log.append(.threadNote, data: ["text": "mind the build"])
    try await log.append(.turnStarted, turn: 1)
    let attempt = try await log.startAttempt(role: "run", turn: 1, provider: AgentProviderID("claude")!, model: nil)
    try await log.appendClaudeLine(#"{"type":"system","subtype":"init","session_id":"s"}"#, turn: 1)
    try await log.appendClaudeLine(
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"chmod +x a.sh"}}]}}"#,
        turn: 1)
    try await log.appendClaudeLine("not json {", turn: 1)
    let pad = String(repeating: "p", count: 200)
    for n in 0..<extraLines { try await log.appendClaudeLine(#"{"type":"stream_event","n":\#(n),"pad":"\#(pad)"}"#, turn: 1) }
    let resultSeq = try await log.appendClaudeLine(denialResult, turn: 1)
    try await log.endAttempt(attempt, outcome: "succeeded")
    try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded", "cost_usd": 0.5])
    let grant: [String: JSONValue] = [
        "scope": "once", "pattern": "Bash(chmod +x a.sh)", "level": "safe", "by": "user", "denial_seq": .int(resultSeq),
    ]
    try await log.append(.grantAdded, data: .object(grant))
    try await log.append(.turnStarted, turn: 2)
    try await log.appendClaudeLine(#"{"type":"system","subtype":"init"}"#, turn: 2)
    try await log.appendClaudeLine(#"{"type":"result","subtype":"success","permission_denials":[]}"#, turn: 2)
    try await log.append(.turnEnded, turn: 2, data: ["result": "succeeded"])
    try await log.append(.reviewDecision, data: ["decision": "accepted"])
    await log.close()
    return Legacy(project: project, id: id)
}

@Suite struct TranscriptCompactorTests {
    private func read(_ project: Project, _ id: String) throws -> EventLogContents {
        try EventLogReader.read(at: project.eventsURL(id))
    }

    @Test func aLegacyThreadKeepsItsStateAndEveryLineAndLosesItsWeight() async throws {
        let thread = try await legacyThread(extraLines: 400)
        let (project, id) = (thread.project, thread.id)
        let url = project.eventsURL(id)
        let before = try read(project, id)
        let stateBefore = ThreadState.derive(from: before.events, id: id)
        let linesBefore = try ThreadLog.read(at: url).transcript()
        let sizeBefore = try Data(contentsOf: url).count
        #expect(before.events.filter { $0.kind == .claude }.count == 406)

        let outcome = try await TranscriptCompactor(project: project).compact(id: id)
        guard case .compacted(let report) = outcome else {
            Issue.record("nothing was compacted: \(outcome)")
            return
        }
        #expect(report.turns == [1, 2] && report.lines == 406 && report.applied)

        // The log: healthy, seq from 1 without gaps, only the result lines left of the claude events.
        let after = try read(project, id)
        #expect(after.isHealthy && after.events.map(\.seq) == Array(1...after.events.count))
        #expect(after.events.filter { $0.kind == .claude }.count == 2)
        #expect(after.events.filter { $0.kind == .claude }.allSatisfy { $0.data["type"] == "result" })
        #expect(try Data(contentsOf: url).count < sizeBefore / 5, "the weight is gone")
        // The thread is the same thread.
        let stateAfter = ThreadState.derive(from: after.events, id: id)
        #expect(stateAfter.decision == "accepted" && stateAfter.totalCostUSD == stateBefore.totalCostUSD)
        #expect(stateAfter.review.deniedTools.map(\.tool) == stateBefore.review.deniedTools.map(\.tool))
        #expect(stateAfter.review.notes.map(\.text) == stateBefore.review.notes.map(\.text))
        // And says the same, line for line, from the files.
        #expect(try ThreadLog.read(at: url).transcript() == linesBefore)
        let turn1 = try #require(after.events.last { $0.kind == .turnEnded && $0.turn == 1 })
        let file = TranscriptFile.url(in: project.threadDirectory(id), turn: 1)
        #expect(!FileManager.default.fileExists(atPath: file.path) && FileManager.default.fileExists(atPath: file.path + ".gz"))
        #expect(turn1.data["transcript"] == TranscriptFile.summary(at: file)?.json, "turn.ended counts what the file holds")
    }

    @Test func theNumbersThatNameASeqFollowTheRenumbering() async throws {
        let thread = try await legacyThread()
        let (project, id) = (thread.project, thread.id)
        _ = try await TranscriptCompactor(project: project).compact(id: id)
        let events = try read(project, id).events

        // The grant still names the denial: the event it points at is now the result line of turn 1.
        let grant = try #require(events.first { $0.kind == .grantAdded })
        let denial = try #require(grant.data["denial_seq"]?.intValue)
        let target = events[denial - 1]
        #expect(target.kind == .claude && target.turn == 1 && target.data["type"] == "result")
        #expect(GrantCandidates.derive(events: events).first?.seqs == [denial])

        // An attempt's id is still `a<seq of its start>` on both lines.
        let started = try #require(events.first { $0.kind == .agentAttemptStarted })
        let ended = try #require(events.first { $0.kind == .agentAttemptEnded })
        #expect(started.data["attempt"] == .string("a\(started.seq)") && ended.data["attempt"] == started.data["attempt"])
    }

    @Test func aSecondRunFindsNothingAndLeavesTheBytesAlone() async throws {
        let thread = try await legacyThread()
        let (project, id) = (thread.project, thread.id)
        let compactor = TranscriptCompactor(project: project)
        _ = try await compactor.compact(id: id)
        let first = try Data(contentsOf: project.eventsURL(id))
        let folder = TranscriptFile.directory(in: project.threadDirectory(id)).path
        let files = try FileManager.default.contentsOfDirectory(atPath: folder)

        #expect(try await compactor.compact(id: id) == .nothingToDo)
        #expect(try Data(contentsOf: project.eventsURL(id)) == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == files)
        let staging = project.threadDirectory(id).appendingPathComponent("transcript.compacting")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func aDryRunChangesNothingAndSaysWhatItWouldDo() async throws {
        let thread = try await legacyThread(extraLines: 100)
        let (project, id) = (thread.project, thread.id)
        let before = try Data(contentsOf: project.eventsURL(id))
        let outcome = try await TranscriptCompactor(project: project).compact(id: id, dryRun: true)
        guard case .compacted(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(!report.applied && report.logBytesAfter < report.logBytesBefore / 4 && report.lines == 106)
        #expect(try Data(contentsOf: project.eventsURL(id)) == before)
        #expect(!FileManager.default.fileExists(atPath: TranscriptFile.directory(in: project.threadDirectory(id)).path))
    }

    @Test func aThreadThatHasNotEndedIsRefusedAndNotTouched() async throws {
        let project = Project(root: Scratch.url("active"))
        let log = try EventLogWriter.open(at: project.eventsURL("g-active"))
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        try await log.appendClaudeLine(#"{"type":"system"}"#, turn: 1)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        await log.close()
        let before = try Data(contentsOf: project.eventsURL("g-active"))
        await #expect(throws: TranscriptCompactor.Failure.active) {
            try await TranscriptCompactor(project: project).compact(id: "g-active")
        }
        #expect(try Data(contentsOf: project.eventsURL("g-active")) == before)
    }

    @Test func aLogWithAProblemIsRefusedAndNotTouched() async throws {
        let thread = try await legacyThread()
        let (project, id) = (thread.project, thread.id)
        let handle = try FileHandle(forWritingTo: project.eventsURL(id))
        try handle.seekToEndOfFile()
        try handle.write(contentsOf: Data("this is not an event\n".utf8))
        try handle.close()
        let before = try Data(contentsOf: project.eventsURL(id))
        let compactor = TranscriptCompactor(project: project)
        await #expect(throws: TranscriptCompactor.Failure.self) { try await compactor.compact(id: id) }
        #expect(try Data(contentsOf: project.eventsURL(id)) == before)
        #expect(!FileManager.default.fileExists(atPath: TranscriptFile.directory(in: project.threadDirectory(id)).path))
    }

    @Test func anInterruptedRunShowsEachLineOnceAndTheNextRunFinishesIt() async throws {
        let thread = try await legacyThread(extraLines: 20)
        let (project, id) = (thread.project, thread.id)
        let url = project.eventsURL(id)
        let original = try Data(contentsOf: url)
        let expected = try ThreadLog.read(at: url).transcript()

        // The same thread, compacted without interruption, is what a finished run must end up as.
        let control = Project(root: Scratch.url("control"))
        try FileManager.default.createDirectory(at: control.threadsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: project.threadDirectory(id), to: control.threadDirectory(id))
        _ = try await TranscriptCompactor(project: control).compact(id: id)

        // A crash between the two steps: the transcript files are in place, the log is still the old one.
        try FileManager.default.copyItem(
            at: TranscriptFile.directory(in: control.threadDirectory(id)),
            to: TranscriptFile.directory(in: project.threadDirectory(id)))
        #expect(try Data(contentsOf: url) == original)

        let shown = try ThreadLog.read(at: url).entries
        let fromLog = shown.contains { if case .transcript(let line) = $0 { line.seq != nil } else { false } }
        #expect(!fromLog, "a turn with a file is shown from it, not twice")
        #expect(shown.filter { if case .transcript = $0 { true } else { false } }.count == expected.count)
        #expect(try ThreadLog.read(at: url).transcript() == expected)

        guard case .compacted = try await TranscriptCompactor(project: project).compact(id: id) else {
            Issue.record("not finished")
            return
        }
        let finished = try read(project, id)
        #expect(finished.isHealthy && finished.events.filter { $0.kind == .claude }.count == 2)
        #expect(try ThreadLog.read(at: url).transcript() == expected)
        #expect(try Data(contentsOf: url) == Data(contentsOf: control.eventsURL(id)), "the log an uninterrupted run leaves")
    }

    @Test func aTranscriptFileThatDiffersFromTheLogIsNotOverwritten() async throws {
        let thread = try await legacyThread()
        let file = TranscriptFile.url(in: thread.project.threadDirectory(thread.id), turn: 1)
        let writer = TranscriptWriter(url: file)
        try writer.append(#"{"type":"system","subtype":"somebody else"}"#)
        writer.close()
        let before = try Data(contentsOf: thread.project.eventsURL(thread.id))

        await #expect(throws: TranscriptCompactor.Failure.self) {
            try await TranscriptCompactor(project: thread.project).compact(id: thread.id)
        }
        #expect(try Data(contentsOf: thread.project.eventsURL(thread.id)) == before)
        #expect(TranscriptFile.lines(at: file, turn: 1).count == 1, "the file that was there is still there")
    }

    @Test func aTurnAlreadyInTheNewShapeIsLeftAlone() async throws {
        let project = Project(root: Scratch.url("mixed"))
        let id = "g-mixed"
        let log = try EventLogWriter.open(at: project.eventsURL(id))
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        try await log.appendClaudeLine(#"{"type":"system","subtype":"init"}"#, turn: 1)
        try await log.appendClaudeLine(#"{"type":"result","permission_denials":[]}"#, turn: 1)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        // Turn 2 as a new Workbench writes it: its lines in a file, the log holds the result line.
        try await log.append(.turnStarted, turn: 2)
        let file = TranscriptFile.url(in: project.threadDirectory(id), turn: 2)
        let writer = TranscriptWriter(url: file)
        try writer.append(#"{"type":"system","subtype":"init"}"#)
        try writer.append(#"{"type":"result","permission_denials":[]}"#)
        writer.close()
        try await log.appendClaudeLine(#"{"type":"result","permission_denials":[]}"#, turn: 2)
        let summary = try #require(TranscriptFile.summary(at: file))
        try await log.append(.turnEnded, turn: 2, data: ["result": "succeeded", "transcript": summary.json])
        try await log.append(.reviewDecision, data: ["decision": "accepted"])
        await log.close()
        TranscriptFile.compress(file)
        let packed = try Data(contentsOf: TranscriptFile.compressedURL(file))

        guard case .compacted(let report) = try await TranscriptCompactor(project: project).compact(id: id) else {
            Issue.record("turn 1 should have been moved")
            return
        }
        #expect(report.turns == [1], "turn 2 is already compact")
        #expect(try Data(contentsOf: TranscriptFile.compressedURL(file)) == packed, "its file was not touched")
        let after = try read(project, id)
        #expect(after.isHealthy && after.events.filter { $0.kind == .claude }.count == 2)
        let kept = try #require(after.events.last { $0.kind == .turnEnded && $0.turn == 2 })
        #expect(kept.data["transcript"] == summary.json)
    }
}
