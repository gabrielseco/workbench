import Foundation

/// Writes a coding turn's output as it arrives. Every provider: each line verbatim and in order in the turn's
/// transcript file, which the bounded activity stream cannot promise. Claude: the `result` line also in the event
/// log as a `claude` event (cost, session and denials are derived from it). Any other provider: the decoder's
/// normalized activity (`agent.activity` events) as well, at most `AgentActivityRecord.maxPerTurn` of them; the
/// file is the lossless copy and a reducer reads the log only, so it counts each activity once. Also the session's
/// confirmation the first time it is named.
/// Called one line at a time by the adapter's driver; read after `completion`, which orders the two.
final class TurnRecorder: AgentRecorder, @unchecked Sendable {
    private let log: EventLogWriter
    let transcript: TranscriptWriter
    private let turn: Int
    private let sessionID: String
    private let provider: String
    private let threadID: String
    private let store: ThreadStore
    private let notify: @Sendable (RunNotice) -> Void
    /// False for a provider that cannot resume: its session is not written to `session.json`.
    private let keepsSession: Bool
    private(set) var sawOutput = false
    private var confirmed = false
    private var written = 0
    /// Items past the cap not yet counted in a `dropped` record.
    private var overCap = 0
    private var lastMark = Date()
    private let now: @Sendable () -> Date
    private var normalized: Bool { provider != "claude" }

    init(
        log: EventLogWriter, transcript: TranscriptWriter, turn: Int, sessionID: String, provider: String,
        threadID: String, store: ThreadStore,
        notify: @escaping @Sendable (RunNotice) -> Void, keepsSession: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keepsSession = keepsSession
        self.now = now
        self.log = log
        self.transcript = transcript
        self.turn = turn
        self.sessionID = sessionID
        self.provider = provider
        self.threadID = threadID
        self.store = store
        self.notify = notify
    }

    func record(_ line: AgentRawLine, activity: [AgentActivity]) async throws {
        if normalized { return try await recordNormalized(line, activity: activity) }
        switch line {
        case .line(let text):
            sawOutput = true
            try await store(text)
            notify(.claudeLine(text))
            // A resume of an id Claude never saw fails at once with no output; a line that names it is the proof.
            if !confirmed, activity.contains(where: { if case .session = $0 { true } else { false } }) {
                confirmed = true
                try store.save(.init(sessionID: sessionID, confirmed: true, provider: provider), for: threadID)
            }
        case .oversized(let preview, let total):
            sawOutput = true
            try transcript.appendOversized(preview: preview, totalBytes: total)
        case .late(let text):
            try await store(text)
        }
    }

    /// The line goes to the transcript; the turn's `result` line also to the log, and first: a runner killed between
    /// the two writes then loses one line of history, not the result that cost and denials are derived from.
    private func store(_ text: String) async throws {
        if Self.isResult(text) { try await log.appendClaudeLine(text, turn: turn) }
        try transcript.append(text)
    }

    private static func isResult(_ text: String) -> Bool {
        guard text.contains("\"result\""),
            case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else { return false }
        return fields["type"]?.stringValue == "result"
    }

    /// Writes the `dropped` record for the activity past the cap not yet counted. Also called once the child has ended.
    func flush() async throws {
        guard normalized, overCap > 0 else { return }
        try await log.append(
            .agentActivity, turn: turn, data: AgentActivityRecord.droppedData(count: overCap, provider: provider))
        overCap = 0
        lastMark = now()
    }

    private func recordNormalized(_ line: AgentRawLine, activity: [AgentActivity]) async throws {
        var items = activity
        // The raw line first: a runner killed between the two writes loses a normalized item, not the original.
        switch line {
        case .line(let text), .late(let text): try transcript.append(text)
        case .oversized(let preview, let total):
            try transcript.appendOversized(preview: preview, totalBytes: total)
            if items.isEmpty { items = [.diagnostic("a line of \(total) bytes was over the size limit and cut")] }
        }
        if case .late = line {} else { sawOutput = true }
        for item in items {
            guard let data = AgentActivityRecord.data(for: item, provider: provider) else { continue }
            if written >= AgentActivityRecord.maxPerTurn {
                overCap += 1
                // A turn that keeps working past the cap still shows signs of life: one count per interval.
                if now().timeIntervalSince(lastMark) >= AgentActivityRecord.dropMarkInterval { try await flush() }
            } else {
                written += 1
                if written == AgentActivityRecord.maxPerTurn { lastMark = now() }
                try await log.append(.agentActivity, turn: turn, data: data)
            }
            if keepsSession, !confirmed, case .session = item {
                confirmed = true
                try store.save(.init(sessionID: sessionID, confirmed: true, provider: provider), for: threadID)
            }
        }
    }
}
