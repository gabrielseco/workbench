import Foundation

/// How a thread is marked in a list: amber needs you, blue working, green done, red a log that cannot be read, grey the rest. The one rule
/// for it, so the app's thread list and the project rail's counts cannot disagree.
public enum ThreadActivity: String, Sendable, Equatable {
    case working, needsYou, done, idle, broken

    /// - Parameters:
    ///   - damaged: the log has problems (a torn line, a bad record): the thread cannot be trusted, and says so in red.
    ///   - outcome: what GitHub said became of the pull request; open when it was not read, so only a recorded merge is ever merged.
    public static func classify(
        attention: Attention, state: ThreadState, damaged: Bool, outcome: PullRequestOutcome = .open
    ) -> ThreadActivity {
        if damaged { return .broken }
        if case .needsYou = attention { return .needsYou }
        if attention == .working { return .working }
        // Green is for work that went somewhere; a thread thrown away, or a pull request closed unmerged, is just over.
        if state.decision == "discarded" || outcome == .closed { return .idle }
        if state.cleaned || state.pullRequest != nil || state.decision != nil { return .done }
        return .idle
    }

    /// A chat thread's mark: blue while a turn is going, otherwise grey (a chat never asks for a decision of its own).
    public static func chat(state: ThreadState) -> ThreadActivity {
        state.decision == nil && state.chat?.open == true ? .working : .idle
    }
}

/// What a project holds that a person may want to know without opening it: how many of its threads need a decision, how many are broken and
/// whether any is working. Read from the logs alone (never GitHub), so a pull request that was merged after the last time the project was
/// open still shows as it was left.
public struct ProjectSummary: Sendable, Equatable {
    public var needsYou = 0
    public var failed = 0
    public var running = 0

    public init(needsYou: Int = 0, failed: Int = 0, running: Int = 0) {
        (self.needsYou, self.failed, self.running) = (needsYou, failed, running)
    }

    public mutating func add(_ activity: ThreadActivity) {
        switch activity {
        case .needsYou: needsYou += 1
        case .broken: failed += 1
        case .working: running += 1
        case .done, .idle: break
        }
    }

    public static func + (lhs: ProjectSummary, rhs: ProjectSummary) -> ProjectSummary {
        ProjectSummary(needsYou: lhs.needsYou + rhs.needsYou, failed: lhs.failed + rhs.failed, running: lhs.running + rhs.running)
    }
}

/// Reads a project's threads for its summary. Read-only: it opens no log for writing and takes no lock. A thread's log is replayed only
/// when its log or goal file changed since the last read (the `Cache`), so a poll of an unchanged project is a `stat` of each file.
public enum ProjectSummaryLoader {
    /// The newest threads read; a project with more has its older ones left out of the count (the list says how many there are).
    public static let maxThreads = 200
    /// The most of a goal file read to tell whether it was approved: the same head the thread list reads.
    static let goalHeadBytes = 64 * 1024

    /// What was read of each thread, kept by the caller between polls.
    public final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: (print: String, activity: ThreadActivity)] = [:]
        /// How many threads were replayed (not taken from here): what a test reads to see that an unchanged project costs nothing.
        public private(set) var replays = 0

        public init() {}

        func activity(_ key: String, print: String, read: () -> ThreadActivity) -> ThreadActivity {
            if let hit = lock.withLock({ known[key].flatMap { $0.print == print ? $0.activity : nil } }) { return hit }
            let fresh = read()
            lock.withLock {
                known[key] = (print, fresh)
                replays += 1
            }
            return fresh
        }

        func forget(except keys: Set<String>) { lock.withLock { known = known.filter { keys.contains($0.key) } } }
    }

    public static func read(project: Project, cache: Cache = Cache()) -> ProjectSummary {
        let store = ThreadStore(project: project)
        let ids = Array(store.threadIDs().sorted(by: >).prefix(maxThreads))
        var summary = ProjectSummary()
        var keys = Set<String>()
        for id in ids {
            let key = project.threadDirectory(id).path
            keys.insert(key)
            let print = fingerprint(project.eventsURL(id)) + "|" + fingerprint(project.goalURL(id))
            summary.add(cache.activity(key, print: print) { activity(project: project, store: store, id: id) })
        }
        cache.forget(except: keys)
        return summary
    }

    /// One thread's mark, from its log and goal file alone.
    static func activity(project: Project, store: ThreadStore, id: String) -> ThreadActivity {
        let contents: EventLogContents
        do { contents = try EventLogReader.read(at: project.eventsURL(id)) } catch { return .broken }
        if contents.events.isEmpty && !contents.problems.isEmpty { return .broken }
        let state = store.state(from: contents.events, id: id)
        if state.isChat, !FileManager.default.fileExists(atPath: project.goalURL(id).path) { return .chat(state: state) }
        var approval: ApprovalState?
        if let handle = try? FileHandle(forReadingFrom: project.goalURL(id)) {
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: goalHeadBytes + 1)) ?? Data()
            if data.count <= goalHeadBytes, let goal = try? GoalFile.parse(String(decoding: data, as: UTF8.self)).goal {
                approval = goal.approval
            } else {
                // Too long to parse from its head: the log says whether it was ever approved, as the list does.
                approval = state.approvedGoalHash != nil ? .approved : .draft
            }
        }
        let spine = ThreadSpine.derive(state: state, approval: approval)
        let attention = Attention.derive(spine: spine, state: state)
        return .classify(attention: attention, state: state, damaged: !contents.problems.isEmpty)
    }

    private static func fingerprint(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? -1)@\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}
