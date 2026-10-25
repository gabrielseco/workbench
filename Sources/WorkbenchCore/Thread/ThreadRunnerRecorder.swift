import Foundation

/// Writes a coding turn's output as it arrives, the same way for every provider: each line verbatim and in order
/// in the turn's transcript file, which the bounded activity stream cannot promise, and the decoder's normalized
/// activity as `agent.activity` events, at most `AgentActivityRecord.maxPerTurn` of them. The file is the lossless
/// copy and a reducer reads the log only, so it counts each activity once. What only the end of a turn knows (cost,
/// session, the refused calls) is on `turn.ended`. Also the session's confirmation the first time it is named.
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
    private var overTools = 0
    private var overDenied = 0
    private var lastMark = Date()
    private let now: @Sendable () -> Date

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
        var items = activity
        // The raw line first: a runner killed between the two writes loses a normalized item, not the original.
        switch line {
        case .line(let text), .late(let text):
            try transcript.append(text)
            if case .line = line, provider == "claude" { notify(.claudeLine(text)) }
        case .oversized(let preview, let total):
            try transcript.appendOversized(preview: preview, totalBytes: total)
            if items.isEmpty { items = [.diagnostic("a line of \(total) bytes was over the size limit and cut")] }
        }
        if case .late = line {} else { sawOutput = true }
        for item in items {
            guard let data = AgentActivityRecord.data(for: item, provider: provider) else { continue }
            if written >= AgentActivityRecord.maxPerTurn {
                overCap += 1
                switch data["type"]?.stringValue {
                case "tool": overTools += 1
                case "permission_denied": overDenied += 1
                default: break
                }
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

    /// Writes the `dropped` record for the activity past the cap not yet counted. Also called once the child has ended.
    func flush() async throws {
        guard overCap > 0 else { return }
        try await log.append(
            .agentActivity, turn: turn,
            data: AgentActivityRecord.droppedData(
                count: overCap, provider: provider, toolCalls: overTools, denied: overDenied))
        (overCap, overTools, overDenied) = (0, 0, 0)
        lastMark = now()
    }
}
