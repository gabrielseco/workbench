import Foundation

public enum ThreadStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case activeThreadExists(String)
    case threadExists(String)
    case noActiveThread
    case invalidName(String)

    public var description: String {
        switch self {
        case .activeThreadExists(let id):
            "thread '\(id)' is still active. Finish it first (accept, discard) or run `workbench abandon`."
        case .threadExists(let id): "thread '\(id)' already exists"
        case .noActiveThread: "there is no active thread. Start one with `workbench goal new <name>`."
        case .invalidName(let name):
            "'\(name)' is not a usable name: letters, digits, '.', '_' and '-' only"
        }
    }
}

/// What the log says about a thread, derived each time it is asked for. Nothing here is stored twice.
public struct ThreadState: Sendable, Equatable {
    public var id: String
    public var createdAt: String?
    public var lastTurn: Int
    public var openTurn: Int?
    /// `accepted`, `discarded` or `abandoned` once the thread has ended.
    public var decision: String?
    public var lastResult: String?
    public var totalCostUSD: Double
    public var sessionID: String?

    public var isActive: Bool { decision == nil }
}

public struct ThreadStore: Sendable {
    public static let terminalDecisions: Set<String> = ["accepted", "discarded", "abandoned"]

    public let project: Project

    public init(project: Project) { self.project = project }

    public func threadIDs() -> [String] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: project.threadsDirectory.path)) ?? []
        return names.filter { SafeNames.isThreadID($0) }.sorted()
    }

    /// Replays one thread's log. A thread with no log yet is a new one.
    public func state(of id: String) -> ThreadState {
        var state = ThreadState(
            id: id, createdAt: nil, lastTurn: 0, openTurn: nil, decision: nil, lastResult: nil,
            totalCostUSD: 0, sessionID: nil)
        guard let contents = try? EventLogReader.read(at: project.eventsURL(id)) else { return state }
        state.lastTurn = contents.lastTurn
        state.openTurn = contents.openTurn
        for event in contents.events {
            switch event.kind {
            case .threadCreated:
                state.createdAt = event.ts
            case .turnStarted:
                if let session = event.data["session_id"]?.stringValue { state.sessionID = session }
            case .turnEnded:
                state.lastResult = event.data["result"]?.stringValue
                switch event.data["cost_usd"] {
                case .double(let d)?: state.totalCostUSD += d
                case .int(let i)?: state.totalCostUSD += Double(i)
                default: break
                }
            case .reviewDecision:
                if let decision = event.data["decision"]?.stringValue,
                    Self.terminalDecisions.contains(decision) {
                    state.decision = decision
                }
            default:
                break
            }
        }
        return state
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
