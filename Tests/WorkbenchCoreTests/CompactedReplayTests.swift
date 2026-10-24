import Foundation
import Testing

@testable import WorkbenchCore

/// What `compact` is for: a thread's replay no longer scales with what `claude` said. Counted in bytes read from the
/// log, not in seconds, so the answer is the same on any machine.
@Suite(.processGate) struct CompactedReplayTests {
    private struct Heavy {
        var project: Project
        var id: String
        var transcriptBytes: Int
    }

    /// A thread with a transcript of about `megabytes` MB in its log, as an older Workbench wrote it, and accepted.
    private func heavyThread(megabytes: Int) async throws -> Heavy {
        let project = Project(root: Scratch.url("heavy"))
        let id = "g-heavy"
        let log = try EventLogWriter.open(at: project.eventsURL(id))
        try await log.append(.threadCreated)
        try await log.append(.turnStarted, turn: 1)
        let pad = String(repeating: "x", count: 1000)
        var bytes = 0
        for n in 0..<(megabytes * 1000) {
            let line = #"{"type":"stream_event","n":\#(n),"pad":"\#(pad)"}"#
            try await log.appendClaudeLine(line, turn: 1)
            bytes += line.utf8.count + 1
        }
        try await log.appendClaudeLine(#"{"type":"result","subtype":"success","permission_denials":[]}"#, turn: 1)
        try await log.append(.turnEnded, turn: 1, data: ["result": "succeeded"])
        try await log.append(.reviewDecision, data: ["decision": "accepted"])
        await log.close()
        return Heavy(project: project, id: id, transcriptBytes: bytes)
    }

    @Test func aCompactedThreadsStatusAndReviewReadAFractionOfItsTranscript() async throws {
        let thread = try await heavyThread(megabytes: 20)
        let (project, id) = (thread.project, thread.id)
        let url = project.eventsURL(id)
        #expect(try Data(contentsOf: url).count > 20_000_000)

        // Before: one replay reads all of it.
        let beforeBytes = EventLogReadCount.bytes(of: url)
        _ = ThreadStore(project: project).state(of: id)
        #expect(EventLogReadCount.bytes(of: url) - beforeBytes > 20_000_000)

        guard case .compacted = try await TranscriptCompactor(project: project).compact(id: id) else {
            Issue.record("not compacted")
            return
        }
        // After: what `status` does (state, summary, the log view) and what `review` adds (the report).
        let start = EventLogReadCount.bytes(of: url)
        let store = ThreadStore(project: project)
        _ = store.state(of: id)
        _ = store.summary(of: id)
        _ = try ThreadLog.read(at: url).entries
        _ = await ReviewLoader(project: project, git: try GitRunner.discover()).load(id: id)
        let read = EventLogReadCount.bytes(of: url) - start
        let limit = thread.transcriptBytes / 20  // 5%
        #expect(read <= limit, "read \(read) bytes of events.jsonl, the limit is \(limit) (5% of \(thread.transcriptBytes))")
        #expect(read < 100_000, "in fact about the size of the log itself: \(read)")
    }
}
