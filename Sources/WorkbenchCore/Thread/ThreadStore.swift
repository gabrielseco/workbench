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
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        return ThreadState.derive(from: events, id: id)
    }

    /// The thread that opened the pull request this thread belongs to: itself, unless it is a review follow-up.
    public func rootID(of id: String) -> String { state(of: id).lineage?.root ?? id }

    /// The follow-ups of `root`, in the order they were made.
    public func followUps(of root: String) -> [ThreadState] {
        threadIDs().map { state(of: $0) }
            .filter { $0.lineage?.root == root }
            .sorted { ($0.lineage?.round ?? 0, $0.id) < ($1.lineage?.round ?? 0, $1.id) }
    }

    /// The one thread that has not ended, if any. If a copied or hand-edited directory makes it
    /// ambiguous, the newest wins; `create` refuses to make a second, so this should be one.
    public func activeThreadID() -> String? {
        threadIDs()
            .map { state(of: $0) }
            .filter(\.isActive)
            .max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }?.id
    }

    /// Makes the thread directory and refuses when another thread is still active (the single-thread rule).
    public func create(id: String) throws {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        if let active = activeThreadID() { throw ThreadStoreError.activeThreadExists(active) }
        // Doctor holds this lock for its whole run; taking and dropping it here is the check.
        if let held = try? ProjectLock.acquire(project) { ProjectLock.release(held) } else {
            throw ThreadStoreError.doctorRunning
        }
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

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case confirmed
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
