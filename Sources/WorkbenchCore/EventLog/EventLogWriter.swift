import Foundation

public enum EventLogError: Error, Equatable, Sendable {
    /// Another writer holds the log. There is exactly one writer by construction.
    case alreadyOpen(path: String)
    /// The file already breaks an invariant. We refuse to append to a damaged log.
    case corrupt([LogProblem])
    /// The append itself would break an invariant.
    case invalid(LogProblem)
    case io(String)
}

/// Single writer for one thread's `events.jsonl`. Assigns `seq`, enforces the turn rules, and holds an
/// exclusive lock for its lifetime, so a second writer cannot exist.
public actor EventLogWriter {
    public static let defaultMaxClaudeLineBytes = 1 << 20
    /// How long `open` waits for a lock that is held. A short wait absorbs the moment a child process
    /// spawned elsewhere in this process still shares the descriptor (between fork and exec); a real
    /// second writer is still refused, just after this delay.
    public static let defaultLockTimeout: TimeInterval = 0.5
    static let truncationPrefixCharacters = 4096

    /// Bytes of a half-written final line removed when the log was opened (kept in a `.truncated` sidecar).
    public nonisolated let repairedTailBytes: Int

    private let handle: FileHandle
    private let maxClaudeLineBytes: Int
    private let now: @Sendable () -> Date
    private var state: LogState
    private var closed = false

    private init(
        handle: FileHandle, state: LogState, repairedTailBytes: Int, maxClaudeLineBytes: Int,
        now: @escaping @Sendable () -> Date
    ) {
        self.handle = handle
        self.state = state
        self.repairedTailBytes = repairedTailBytes
        self.maxClaudeLineBytes = maxClaudeLineBytes
        self.now = now
    }

    public static func open(
        at url: URL,
        maxClaudeLineBytes: Int = defaultMaxClaudeLineBytes,
        lockTimeout: TimeInterval = defaultLockTimeout,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> EventLogWriter {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw EventLogError.io("cannot create \(url.deletingLastPathComponent().path): \(error)")
        }

        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw EventLogError.io("cannot open \(url.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try acquireLock(fd: fd, path: url.path, timeout: lockTimeout)

        let existing: Data
        do { existing = try handle.readToEnd() ?? Data() } catch {
            throw EventLogError.io("cannot read \(url.path): \(error)")
        }
        let contents = EventLogReader.parse(existing)
        guard contents.problems.isEmpty else { throw EventLogError.corrupt(contents.problems) }

        var repaired = 0
        if let tail = contents.truncatedTail {
            try keepTail(tail, beside: url)
            guard ftruncate(fd, off_t(contents.completeByteCount)) == 0 else {
                throw EventLogError.io("cannot truncate \(url.path): \(String(cString: strerror(errno)))")
            }
            repaired = tail.count
        }

        var state = LogState()
        for event in contents.events { state.apply(event) }
        return EventLogWriter(
            handle: handle, state: state, repairedTailBytes: repaired,
            maxClaudeLineBytes: maxClaudeLineBytes, now: now)
    }

    /// Releases the lock and closes the file. Appends after this throw. Prefer this to letting the writer
    /// go out of scope: deallocation of an actor is not a point you can order other work against.
    public func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }

    /// The turn that started and has not ended, if any.
    public var openTurn: Int? { state.openTurn }
    /// The turn whose check started and has not ended, if any.
    public var openCheck: Int? { state.openCheck }
    /// The turn whose verify step started and has not ended, if any.
    public var openVerify: Int? { state.openVerify }
    /// The `seq` the next append will get.
    public var nextSeq: Int { state.nextSeq }
    /// The highest turn number started so far, 0 for a thread with no turns.
    public var lastTurn: Int { state.lastTurn }

    /// Appends a structured event.
    @discardableResult
    public func append(_ kind: EventKind, turn: Int = 0, data: JSONValue = [:]) throws -> Event {
        let event = Event(seq: state.nextSeq, ts: timestamp(), turn: turn, kind: kind, data: data)
        if let problem = state.check(event) { throw EventLogError.invalid(problem) }
        try write(event, dataJSON: try Self.json(data))
        return event
    }

    /// Appends one raw line from `claude`, stored verbatim when it is valid JSON. Invalid JSON is wrapped as
    /// `{"invalid_json": "<line>"}` and oversized lines as a truncation marker, so the run continues and
    /// the log stays bounded.
    @discardableResult
    public func appendClaudeLine(_ raw: String, turn: Int) throws -> Int {
        let seq = state.nextSeq
        let dataJSON: String
        let size = raw.utf8.count
        if size > maxClaudeLineBytes {
            dataJSON = try Self.json([
                "truncated": true,
                "original_bytes": .int(size),
                "prefix": .string(String(raw.prefix(Self.truncationPrefixCharacters))),
            ])
        } else if Self.isSingleLineJSON(raw) {
            dataJSON = raw
        } else {
            dataJSON = try Self.json(["invalid_json": .string(raw)])
        }
        let event = Event(seq: seq, ts: timestamp(), turn: turn, kind: .claude, data: .null)
        if let problem = state.check(event) { throw EventLogError.invalid(problem) }
        try write(event, dataJSON: dataJSON)
        return seq
    }

    /// Records a line the process runner already cut short, in the same shape `appendClaudeLine` uses for a
    /// line over the size limit.
    @discardableResult
    public func appendOversizedClaudeLine(preview: String, totalBytes: Int, turn: Int) throws -> Int {
        let seq = state.nextSeq
        let event = Event(seq: seq, ts: timestamp(), turn: turn, kind: .claude, data: .null)
        if let problem = state.check(event) { throw EventLogError.invalid(problem) }
        let dataJSON = try Self.json([
            "truncated": true,
            "original_bytes": .int(totalBytes),
            "prefix": .string(String(preview.prefix(Self.truncationPrefixCharacters))),
        ])
        try write(event, dataJSON: dataJSON)
        return seq
    }

    /// Closes an orphaned turn (left behind by a runner that died) with a synthetic `interrupted` end.
    /// Returns nil when there is nothing to recover.
    @discardableResult
    public func recoverOrphanedTurn() throws -> Event? {
        guard let turn = state.openTurn else { return nil }
        // The turn's own attempt ends first, so no attempt outlives the turn it belongs to.
        try recoverOrphanedAttempts(roles: ["run"])
        return try append(
            .turnEnded, turn: turn,
            data: ["result": "interrupted", "synthetic": true, "exit_code": nil])
    }

    /// Closes an orphaned check (its runner died while the command ran) with a synthetic `interrupted`.
    /// Returns nil when there is nothing to recover.
    @discardableResult
    public func recoverOrphanedCheck() throws -> Event? {
        guard let turn = state.openCheck else { return nil }
        return try append(
            .checkRan, turn: turn,
            data: ["result": "interrupted", "synthetic": true, "exit_code": nil])
    }

    /// Closes an orphaned verify step (its runner died while the command ran) with a synthetic `interrupted`.
    @discardableResult
    public func recoverOrphanedVerify() throws -> Event? {
        guard let turn = state.openVerify else { return nil }
        return try append(
            .verifyEnded, turn: turn,
            data: ["result": "interrupted", "synthetic": true, "exit_code": nil])
    }

    /// True while an `agent.attempt.started` has no end.
    public var hasOpenAttempt: Bool { !state.openAttempts.isEmpty }

    /// Records that a provider process is about to be started for `role`, and returns the attempt's id (`a` and
    /// the `seq` of its start, so it is unique in this log and stable across a replay). A refusal that spawns
    /// nothing passes `spawned: false` and is closed at once with `endAttempt`.
    @discardableResult
    public func startAttempt(
        role: String, stage: String? = nil, turn: Int = 0, round: Int? = nil, provider: AgentProviderID, model: String?,
        spawned: Bool = true
    ) throws -> String {
        let id = "a\(state.nextSeq)"
        var data: [String: JSONValue] = [
            "attempt": .string(id), "role": .string(role), "provider": .string("\(provider)"),
            "model": model.map { .string($0) } ?? .null,
        ]
        if let stage { data["stage"] = .string(stage) }
        if let round { data["round"] = .int(round) }
        if !spawned { data["spawned"] = false }
        try append(.agentAttemptStarted, turn: turn, data: .object(data))
        return id
    }

    /// Closes an attempt. A second call for the same id writes nothing, so recovery and the normal end cannot both
    /// record one.
    @discardableResult
    public func endAttempt(_ id: String, outcome: String, reason: String? = nil, synthetic: Bool = false) throws -> Event? {
        guard let started = state.openAttempts[id] else { return nil }
        var data: [String: JSONValue] = ["attempt": .string(id), "outcome": .string(outcome)]
        // The end stands alone: it says whose attempt it was, as `plan.ended` repeats what its start knew.
        for key in ["role", "stage", "round", "provider", "model"] { if let value = started.data[key] { data[key] = value } }
        if let reason { data["reason"] = .string(reason) }
        if synthetic { data["synthetic"] = true }
        return try append(.agentAttemptEnded, turn: started.turn, data: .object(data))
    }

    /// Closes the attempts of `roles` (all when nil) that a runner killed mid-run left open, as `interrupted`.
    @discardableResult
    public func recoverOrphanedAttempts(roles: Set<String>? = nil) throws -> [Event] {
        var closed: [Event] = []
        for (id, started) in state.openAttempts.sorted(by: { $0.value.seq < $1.value.seq }) {
            if let roles, !roles.contains(started.data["role"]?.stringValue ?? "") { continue }
            if let event = try endAttempt(id, outcome: "interrupted", synthetic: true) { closed.append(event) }
        }
        return closed
    }

    /// Closes a goal draft, judge or review round whose process was killed (a start with no end), and the attempts that belong to
    /// them, each as a synthetic `interrupted`. The round still counts toward `max_rounds` (its start is still in
    /// the log) and an interrupted end is never a pass. Run it, holding the log, before any new work; a second call
    /// writes nothing.
    @discardableResult
    public func recoverOrphanedEvaluations() throws -> [Event] {
        let judging = state.judgeStarts
        let reviewing = state.reviewStarts
        let drafting = state.draftStarts
        guard !judging.isEmpty || !reviewing.isEmpty || !drafting.isEmpty || !state.openAttempts.isEmpty else { return [] }
        var closed = try recoverOrphanedAttempts(roles: ["judge", "review", "goal"])
        for started in drafting.reversed() {
            var data: [String: JSONValue] = ["ok": false, "reason": "interrupted", "synthetic": true]
            for key in ["attempt", "provider", "model"] { if let value = started.data[key] { data[key] = value } }
            closed.append(try append(.goalDraftFinished, turn: started.turn, data: .object(data)))
        }
        for started in judging.reversed() {
            var data: [String: JSONValue] = ["ok": false, "reason": "interrupted", "synthetic": true]
            // What the start says was asked for, so the end is attributed too; absent in a log from before provider selection.
            for key in ["argv", "provider", "model"] { if let value = started.data[key] { data[key] = value } }
            closed.append(try append(.judgeRan, turn: started.turn, data: .object(data)))
        }
        for started in reviewing.reversed() {
            let isStage = started.kind == .reviewStageStarted
            var data: [String: JSONValue] = ["ok": false, "verdict": .null, "reason": "interrupted", "synthetic": true]
            for key in ["round", "pr", "head_sha", "provider", "model"] {
                if let value = started.data[key] { data[key] = value }
            }
            if isStage, let stage = started.data["stage"] { data["stage"] = stage }
            closed.append(
                try append(isStage ? .reviewStageFinished : .prReviewFinished, turn: started.turn, data: .object(data)))
        }
        return closed
    }

    /// True while a `plan.started` has no `plan.ended`.
    public var hasOpenPlan: Bool { state.planStart != nil }

    /// Closes a plan whose process died (`plan.started` and no `plan.ended`) with a synthetic `interrupted`.
    /// `goal_hash` and `base_commit` come from the start, so the end record stands alone.
    @discardableResult
    public func recoverOrphanedPlan() throws -> Event? {
        guard let started = state.planStart else { return nil }
        var data: [String: JSONValue] = ["ok": false, "reason": "interrupted", "synthetic": true]
        for key in ["goal_hash", "base_commit"] { if let value = started.data[key] { data[key] = value } }
        return try append(.planEnded, turn: started.turn, data: .object(data))
    }

    /// True while a `verifier.started` has no `verifier.ended`.
    public var hasOpenVerifier: Bool { state.verifierStart != nil }

    /// Closes a verifier whose process died (`verifier.started` and no `verifier.ended`) with a synthetic
    /// `interrupted`, so every start has exactly one end.
    @discardableResult
    public func recoverOrphanedVerifier() throws -> Event? {
        guard let started = state.verifierStart else { return nil }
        // The app it started went down with it (the caller sweeps the worktree); say so before the verifier's end.
        if let run = state.runStart {
            try append(.runEnded, turn: run.turn, data: ["ready": false, "reason": "interrupted", "synthetic": true])
        }
        let data: [String: JSONValue] = ["ok": false, "reason": "interrupted", "synthetic": true]
        return try append(.verifierEnded, turn: started.turn, data: .object(data))
    }

    // MARK: - Internals

    private static func acquireLock(fd: Int32, path: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw EventLogError.io("cannot lock \(path): \(String(cString: strerror(code)))")
            }
            if Date() >= deadline { throw EventLogError.alreadyOpen(path: path) }
            usleep(2_000)
        }
    }

    private func write(_ event: Event, dataJSON: String) throws {
        guard !closed else { throw EventLogError.io("event log is closed") }
        let line =
            "{\"v\":\(event.v),\"seq\":\(event.seq),\"ts\":\(try Self.json(.string(event.ts))),"
            + "\"turn\":\(event.turn),\"kind\":\(try Self.json(.string(event.kind.rawValue))),"
            + "\"data\":\(dataJSON)}\n"
        do { try handle.write(contentsOf: Data(line.utf8)) } catch {
            throw EventLogError.io("append failed: \(error)")
        }
        state.apply(event)
    }

    private func timestamp() -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now())
    }

    static func json(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) } catch {
            throw EventLogError.io("cannot encode payload: \(error)")
        }
    }

    static func isSingleLineJSON(_ raw: String) -> Bool {
        guard !raw.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) != nil
    }

    private static func keepTail(_ tail: Data, beside url: URL) throws {
        let sidecar = url.appendingPathExtension("truncated")
        let fd = Darwin.open(sidecar.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw EventLogError.io("cannot open \(sidecar.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: tail)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch {
            throw EventLogError.io("cannot write \(sidecar.path): \(error)")
        }
    }
}
