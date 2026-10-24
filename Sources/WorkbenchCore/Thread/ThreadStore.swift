import Foundation

public enum ThreadStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case activeThreadExists(String)
    case threadExists(String)
    case noActiveThread
    case invalidName(String)
    /// `workbench doctor` holds the project; a thread started now would run its check next to doctor's.
    case doctorRunning

    public var description: String {
        switch self {
        case .doctorRunning: "`workbench doctor` is running in this project; try again when it has finished."
        case .activeThreadExists(let id):
            "thread '\(id)' is still active. Finish it first (accept, discard) or run `workbench abandon`."
        case .threadExists(let id): "thread '\(id)' already exists"
        case .noActiveThread: "there is no active thread. Start one with `workbench goal new <name>`."
        case .invalidName(let name):
            "'\(name)' is not a usable name: letters, digits, '.', '_' and '-' only"
        }
    }
}

public struct ThreadStore: Sendable {
    public let project: Project

    public init(project: Project) { self.project = project }

    public func threadIDs() -> [String] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: project.threadsDirectory.path)) ?? []
        return names.filter { SafeNames.isThreadID($0) }.sorted()
    }

    /// Replays one thread's log. A thread with no log yet is a new one.
    public func state(of id: String) -> ThreadState {
        state(from: (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? [], id: id)
    }

    /// The state for events already replayed. While a turn is open its progress also reads the turn's
    /// transcript file, since the lines of a turn are not in the log.
    public func state(from events: [Event], id: String) -> ThreadState {
        let state = ThreadState.derive(from: events, id: id)
        guard let open = state.openTurn else { return state }
        let lines = TranscriptFile.lines(at: TranscriptFile.url(in: project.threadDirectory(id), turn: open), turn: open)
        return lines.isEmpty ? state : ThreadState.derive(from: events, id: id, transcript: lines)
    }

    /// What finding the active, newest or related thread needs, without replaying the whole log.
    public struct Summary: Sendable, Equatable {
        public var id: String
        public var createdAt: String?
        public var lineage: ThreadLineage?
        public var decision: String?
        public var isActive: Bool { decision == nil }
    }

    /// Reads `createdAt`, `lineage` and `decision` the way `ThreadState.derive` does, but decodes only the
    /// `thread.created` and `review.decision` lines. A log can be megabytes of verbatim `claude` lines, and
    /// listing threads must not parse all of them; a line that merely quotes those kinds is decoded and ignored.
    /// The search is `memmem` over a copy of the file, not a mapping (the writer truncates a torn tail, and a
    /// page of a mapping past the new end raises SIGBUS): splitting into lines and searching each through Foundation
    /// cost about a second over 94 MB of logs.
    public func summary(of id: String) -> Summary {
        var summary = Summary(id: id)
        guard let data = try? Data(contentsOf: project.eventsURL(id)) else { return summary }
        let decoder = JSONDecoder()
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            // Only a line ended by a newline counts, as in a replay: a torn last line is not an event.
            var pos = 0
            let needles = [Array("thread.created".utf8), Array("review.decision".utf8)]
            var next = [Int?](repeating: nil, count: needles.count)
            var searched = [Bool](repeating: false, count: needles.count)
            while pos < bytes.count {
                var hit: Int?
                for index in needles.indices {
                    if !searched[index] || (next[index].map { $0 < pos } ?? false) {
                        next[index] = Self.find(needles[index], in: base, from: pos, count: bytes.count)
                        searched[index] = true
                    }
                    if let found = next[index], hit.map({ found < $0 }) ?? true { hit = found }
                }
                guard let hit else { return }
                let start = Self.lineStart(before: hit, in: base)
                guard let end = memchr(base + hit, 0x0A, bytes.count - hit) else { return }
                let lineEnd = base.distance(to: UnsafeRawPointer(end))
                pos = lineEnd + 1
                let line = Data(bytes: base + start, count: lineEnd - start)
                guard let event = try? decoder.decode(Event.self, from: line) else { continue }
                switch event.kind {
                case .threadCreated:
                    summary.createdAt = event.ts
                    summary.lineage = ThreadState.lineage(event)
                case .reviewDecision:
                    if let decision = event.data["decision"]?.stringValue,
                        ThreadState.terminalDecisions.contains(decision) {
                        summary.decision = decision
                    }
                default:
                    break
                }
            }
        }
        return summary
    }

    private static func find(_ needle: [UInt8], in base: UnsafeRawPointer, from: Int, count: Int) -> Int? {
        guard from < count, let found = memmem(base + from, count - from, needle, needle.count) else { return nil }
        return base.distance(to: UnsafeRawPointer(found))
    }

    private static func lineStart(before offset: Int, in base: UnsafeRawPointer) -> Int {
        var index = offset
        while index > 0, base.load(fromByteOffset: index - 1, as: UInt8.self) != 0x0A { index -= 1 }
        return index
    }

    /// Every thread's summary, in id order.
    public func summaries() -> [Summary] { threadIDs().map { summary(of: $0) } }

    /// The thread that opened the pull request this thread belongs to: itself, unless it is a review follow-up.
    public func rootID(of id: String) -> String { summary(of: id).lineage?.root ?? id }

    /// The newest thread by creation time, active or not.
    public func newestThreadID() -> String? {
        summaries().max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }?.id
    }

    /// The follow-ups of `root`, in the order they were made.
    public func followUps(of root: String) -> [ThreadState] {
        summaries().filter { $0.lineage?.root == root }
            .map { state(of: $0.id) }
            .sorted { ($0.lineage?.round ?? 0, $0.id) < ($1.lineage?.round ?? 0, $1.id) }
    }

    /// The pid of the `workbench run` holding this thread, if there is one: same pid *and* same start time
    /// as recorded, so a process that merely reused the number is not mistaken for it.
    public func runnerPID(id: String) -> Int32? {
        guard
            let data = try? Data(contentsOf: project.runnerURL(id)),
            let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pid = (info["pid"] as? NSNumber)?.int32Value,
            let seconds = (info["started_seconds"] as? NSNumber)?.uint64Value,
            let micros = (info["started_micros"] as? NSNumber)?.uint64Value
        else { return nil }
        let expected = ProcessMember(pid: pid, startSeconds: seconds, startMicros: micros)
        return ProcessTree.isAlive(expected) ? pid : nil
    }

    /// The one thread that has not ended, if any. If a copied or hand-edited directory makes it
    /// ambiguous, the newest wins; `create` refuses to make a second, so this should be one.
    public func activeThreadID() -> String? {
        summaries()
            .filter(\.isActive)
            .max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }?.id
    }

    /// The thread with a live runner (a turn, check, verify, plan or judge in progress), if any. A crashed runner
    /// leaves an open turn in the log but no live process, so the log alone cannot say.
    public func threadWithLiveRunner() -> String? {
        threadIDs().first { summary(of: $0).isActive && runnerPID(id: $0) != nil }
    }

    /// Doctor holds the project lock for its whole run; taking and dropping it here is the check. A run calls it
    /// after writing its `runner.json`, and doctor looks for that file after taking the lock, so one sees the other.
    public func requireNoDoctor() throws {
        if let held = try? ProjectLock.acquire(project) { ProjectLock.release(held) } else {
            throw ThreadStoreError.doctorRunning
        }
    }

    /// Makes the thread directory and refuses when another thread is still active (the single-thread rule).
    public func create(id: String) throws {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        if let active = activeThreadID() { throw ThreadStoreError.activeThreadExists(active) }
        try requireNoDoctor()
        guard !FileManager.default.fileExists(atPath: project.threadDirectory(id).path) else {
            throw ThreadStoreError.threadExists(id)
        }
        try FileManager.default.createDirectory(
            at: project.threadDirectory(id), withIntermediateDirectories: true)
    }

    // MARK: session.json

    public struct Session: Codable, Equatable, Sendable {
        public var sessionID: String
        /// True once a stream line carrying this session id has been seen: the CLI has the session.
        public var confirmed: Bool
        /// The provider that made the handle; absent in a file written before P9, which only Claude wrote.
        public var provider: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case confirmed
            case provider
        }
    }

    public func session(of id: String) -> Session? {
        guard let data = try? Data(contentsOf: project.sessionURL(id)) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func save(_ session: Session, for id: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(session).write(to: project.sessionURL(id), options: .atomic)
    }
}
