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

    /// A chat thread's mark: red when its log is damaged, blue while a turn is going, otherwise grey (a chat never asks for a decision of
    /// its own).
    public static func chat(state: ThreadState, damaged: Bool = false) -> ThreadActivity {
        if damaged { return .broken }
        return state.decision == nil && state.chat?.open == true ? .working : .idle
    }
}

/// What a project holds that a person may want to know without opening it: how many of its threads need a decision, how many are broken and
/// whether any is working. Read from the logs, plus what GitHub last said of each thread's pull request when the caller has it (the app
/// keeps that per project and reads it in the background), so a pull request merged after the last time the project was open counts as it
/// is, not as it was left.
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
        private var created: [String: String] = [:]
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

        /// When a thread was created, read once from its log's first line.
        func createdAt(_ key: String, read: () -> String) -> String {
            if let known = lock.withLock({ created[key] }) { return known }
            let value = read()
            lock.withLock { created[key] = value }
            return value
        }

        func forget(except keys: Set<String>) {
            lock.withLock {
                known = known.filter { keys.contains($0.key) }
                created = created.filter { keys.contains($0.key) }
            }
        }
    }

    /// The project's summary, or nil when its threads folder could not be listed (a folder that is there but cannot be read, such as a volume
    /// that went away): that is not "no threads", and the caller keeps the last count. No threads folder at all is a project with none.
    /// - Parameter pullRequests: what GitHub last said of each thread's pull request, by thread id; a thread missing here is read from its
    ///   log alone, which never says merged without a recorded merge.
    public static func read(
        project: Project, cache: Cache = Cache(), pullRequests: [String: PRStatus] = [:]
    ) -> ProjectSummary? {
        let store = ThreadStore(project: project)
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: project.threadsDirectory.path) } catch {
            let missing = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError
            guard missing else { return nil }
            names = []
        }
        // The newest by when they were created, as the list orders them: an id says nothing of age (a name may start with `a` or `z`).
        let newestFirst = names.filter { SafeNames.isThreadID($0) }.map { id in
            (id, cache.createdAt(project.threadDirectory(id).path) { firstLineCreatedAt(project.eventsURL(id)) })
        }
        .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
        let ids = newestFirst.prefix(maxThreads).map(\.0)
        var summary = ProjectSummary()
        var keys = Set<String>()
        for id in ids {
            let key = project.threadDirectory(id).path
            keys.insert(key)
            let status = pullRequests[id]
            let files = fingerprint(project.eventsURL(id)) + "|" + fingerprint(project.goalURL(id))
            let print = files + "|" + (status.map { "\($0)" } ?? "")
            summary.add(
                cache.activity(key, print: print) { activity(project: project, store: store, id: id, pullRequest: status) })
        }
        cache.forget(except: keys)
        return summary
    }

    /// `thread.created`'s time, from the log's first line alone; "" when it cannot be told (the thread sorts last).
    public static func firstLineCreatedAt(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8_192)) ?? Data()
        guard let line = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
            let event = try? JSONDecoder().decode(Event.self, from: Data(line))
        else { return "" }
        return event.ts
    }

    /// One thread's mark, from its log and goal file alone.
    static func activity(
        project: Project, store: ThreadStore, id: String, pullRequest status: PRStatus? = nil
    ) -> ThreadActivity {
        let contents: EventLogContents
        do { contents = try EventLogReader.read(at: project.eventsURL(id)) } catch { return .broken }
        if contents.events.isEmpty && !contents.problems.isEmpty { return .broken }
        let state = store.state(from: contents.events, id: id)
        if state.isChat, !FileManager.default.fileExists(atPath: project.goalURL(id).path) {
            return .chat(state: state, damaged: !contents.problems.isEmpty)
        }
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
        // As the thread list reads it: only a status for the pull request the log names counts, and a merge the log recorded needs no read.
        let status = status.flatMap { $0.number == state.pullRequest?.number ? $0 : nil }
        var outcome = PullRequestOutcome.open
        if state.isMerged || status?.state == .merged {
            outcome = .merged
        } else if status?.state == .closed {
            outcome = .closed
        }
        let checks = status?.checksError == nil ? status?.checks : nil
        let spine = ThreadSpine.derive(
            state: state, approval: approval, outcome: outcome, checks: checks, currentHead: status?.head)
        let attention = Attention.derive(spine: spine, state: state, checks: checks, outcome: outcome, currentHead: status?.head)
        return .classify(attention: attention, state: state, damaged: !contents.problems.isEmpty, outcome: outcome)
    }

    private static func fingerprint(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? -1)@\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}
