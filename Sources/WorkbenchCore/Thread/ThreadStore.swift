import Foundation

public enum ThreadStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case activeThreadExists(String)
    case threadExists(String)
    case noActiveThread
    /// Several threads are active and the command did not say which one.
    case severalActive([String])
    /// `max_active_threads` threads are already active.
    case tooManyActive([String], max: Int)
    case invalidName(String)
    /// `workbench doctor` holds the project; a thread started now would run its check next to doctor's.
    case doctorRunning
    /// Another command is admitting a thread at this moment and did not finish within the wait.
    case admissionBusy

    public var description: String {
        switch self {
        case .admissionBusy: "another thread is being created in this project; try again in a moment."
        case .doctorRunning: "`workbench doctor` is running in this project; try again when it has finished."
        case .activeThreadExists(let id):
            "thread '\(id)' is still active. Finish it first (accept, discard) or run `workbench abandon`."
        case .severalActive(let ids):
            "\(ids.count) threads are active (\(ids.joined(separator: ", "))): name one with --thread."
        case .tooManyActive(let ids, let max):
            "\(ids.count) of \(max) allowed threads are active (\(ids.joined(separator: ", "))). Finish one first "
                + "(accept, discard), run `workbench abandon`, or raise `max_active_threads`."
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

    /// The state for events already replayed.
    public func state(from events: [Event], id: String) -> ThreadState {
        ThreadState.derive(from: events, id: id)
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
        EventLogReadCount.record(project.eventsURL(id), bytes: data.count)
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
    public func runnerPID(id: String) -> Int32? { holder(id: id)?.pid }

    /// A Claude session handed to Herdr holds the thread too: its supervisor writes `runner.json` with `"session": "herdr"` and no
    /// start microseconds (a shell script cannot read them), so the start time matches to within `sessionStartSlack` seconds.
    public func holdsHerdrSession(id: String) -> Bool { holder(id: id)?.herdrSession == true }

    static let sessionStartSlack: UInt64 = 2

    private func holder(id: String) -> (pid: Int32, herdrSession: Bool)? {
        guard
            let data = try? Data(contentsOf: project.runnerURL(id)),
            let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pid = (info["pid"] as? NSNumber)?.int32Value,
            let seconds = (info["started_seconds"] as? NSNumber)?.uint64Value
        else { return nil }
        guard let current = ProcessTree.member(for: pid) else { return nil }
        if let micros = (info["started_micros"] as? NSNumber)?.uint64Value {
            let expected = ProcessMember(pid: pid, startSeconds: seconds, startMicros: micros)
            return current == expected ? (pid, false) : nil
        }
        // The marker's time is read after the process started, so a process that reused the pid started later than it.
        guard info["session"] as? String == "herdr", current.startSeconds <= seconds,
            seconds - current.startSeconds <= Self.sessionStartSlack
        else { return nil }
        return (pid, true)
    }

    /// The one thread that has not ended, if any. If a copied or hand-edited directory makes it
    /// ambiguous, the newest wins; `create` refuses to make a second, so this should be one.
    public func activeThreadIDs() -> [String] {
        summaries()
            .filter(\.isActive)
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }.map(\.id)
    }

    /// The most recently created active thread: what a view shows when nobody picked one. A command that changes a thread
    /// does not use it; with several active it needs a name (`Context.threadID`).
    public func newestActiveThreadID() -> String? { activeThreadIDs().first }

    /// What a new thread meets: nothing when a slot is free, else the active threads that fill them.
    public func fullThreads(maxActive: Int) -> [String]? {
        let active = activeThreadIDs()
        return active.count >= maxActive ? active : nil
    }

    /// The thread in the way of a new one, for a flow that may abandon it: nil when a slot is free, the one active thread
    /// when the cap is one. With a higher cap and no free slot it throws, since no flow picks which of several to end.
    public func blockingThread(maxActive: Int) throws -> String? {
        guard let full = fullThreads(maxActive: maxActive) else { return nil }
        if maxActive == 1 { return full[0] }
        throw ThreadStoreError.tooManyActive(full, max: maxActive)
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

    /// The threads, other than `excluding`, whose runner is alive and whose check has started and not ended. A crashed runner
    /// leaves an open check in its log but no live process, so the log alone would count it for ever.
    public func runningChecks(excluding id: String? = nil) -> [String] {
        threadIDs().filter { other in
            guard other != id, runnerPID(id: other) != nil else { return false }
            return (try? EventLogReader.read(at: project.eventsURL(other)))?.openCheck != nil
        }
    }

    /// The name a chat was started under: its id is `g-<yyyy-MM-dd>-<name>`. The whole name, never the tail of one, so `foo` is
    /// not the chat `bar-foo`.
    public static func chatName(of id: String) -> String? {
        let parts = id.split(separator: "-", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "g", parts[1...3].allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return String(parts[4])
    }

    /// An exclusive lock on the `threads/` directory itself (no file is left), held while a thread is admitted. The wait is
    /// short and bounded: the critical section is a directory listing and a mkdir.
    static func admit(_ directory: URL) throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ThreadStoreError.admissionBusy }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(fd)
                throw ThreadStoreError.admissionBusy
            }
            usleep(2_000)
        }
        return fd
    }

    /// The same lock for code that is already async: the wait yields instead of holding a thread, so the holder, which may be
    /// waiting on the executor itself (a check holds it across a log append), can always run and let go.
    static func admit(_ directory: URL) async throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ThreadStoreError.admissionBusy }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(fd)
                throw ThreadStoreError.admissionBusy
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return fd
    }

    /// Makes the thread directory and refuses when `maxActive` threads are already active (one is the single-thread rule).
    public func create(id: String, maxActive: Int = 1) throws {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        // Counting the active threads and making the folder are one step: two commands at once must not both see a free slot.
        try FileManager.default.createDirectory(at: project.threadsDirectory, withIntermediateDirectories: true)
        let admission = try Self.admit(project.threadsDirectory)
        defer { close(admission) }
        if let full = fullThreads(maxActive: maxActive) {
            throw maxActive == 1
                ? ThreadStoreError.activeThreadExists(full[0]) : ThreadStoreError.tooManyActive(full, max: maxActive)
        }
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
