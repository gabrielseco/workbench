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
    static let truncationPrefixCharacters = 4096

    /// Bytes of a half-written final line removed when the log was opened (kept in a `.truncated` sidecar).
    public nonisolated let repairedTailBytes: Int

    private let handle: FileHandle
    private let maxClaudeLineBytes: Int
    private let now: @Sendable () -> Date
    private var state: LogState

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
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw EventLogError.alreadyOpen(path: url.path)
        }

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

    /// The turn that started and has not ended, if any.
    public var openTurn: Int? { state.openTurn }
    /// The `seq` the next append will get.
    public var nextSeq: Int { state.nextSeq }

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

    /// Closes an orphaned turn (left behind by a runner that died) with a synthetic `interrupted` end.
    /// Returns nil when there is nothing to recover.
    @discardableResult
    public func recoverOrphanedTurn() throws -> Event? {
        guard let turn = state.openTurn else { return nil }
        return try append(
            .turnEnded, turn: turn,
            data: ["result": "interrupted", "synthetic": true, "exit_code": nil])
    }

    // MARK: - Internals

    private func write(_ event: Event, dataJSON: String) throws {
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
