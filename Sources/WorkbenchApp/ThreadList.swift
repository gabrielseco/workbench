import Foundation
import Observation
import WorkbenchCore

/// What a thread's row says: the mark carries the colour and the symbol, the line says it in words.
enum ThreadMark: String, Equatable, Sendable {
    case working, needsYou, done, idle, broken

    init(activity: ThreadActivity) { self = ThreadMark(rawValue: activity.rawValue) ?? .idle }
}

struct ThreadRow: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var mark: ThreadMark
    /// One line of state, in the toolbar pill's words.
    var line: String
    /// The number of the shipped pull request whose fate only GitHub knows (accepted, not cleaned): what the store reads for the row.
    var pullRequest: Int?
}

/// The project's threads for the list: the newest `ThreadListLoader.maxRows`, and how many older ones there are.
struct ThreadListing: Equatable, Sendable {
    var rows: [ThreadRow] = []
    var older = 0
}

/// The list's data, kept current by the store.
@MainActor @Observable final class ThreadListModel {
    var listing = ThreadListing()
    /// What the files looked like when `listing` was read, so a poll rebuilds only when something moved.
    @ObservationIgnored var signature: ThreadListLoader.Signature?
    /// What GitHub last said of each listed thread's pull request. A read that failed leaves none, so the row says what the log says.
    @ObservationIgnored var pullRequests: [String: PRStatus] = [:]
    /// When each was last asked for, so a poll asks again only after `pullRequestInterval`.
    @ObservationIgnored var pullRequestsReadAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var readingPullRequests = false
    /// The first read of GitHub for threads it has not been asked about yet is running: the rail says so. A later read of a pull request
    /// that is still open is quiet, so the line is not on screen for a second every few minutes.
    var syncing = false
    /// Merges GitHub confirmed whose `pr.merged` could not be written (the log was held): tried again on the next poll.
    @ObservationIgnored var unwrittenMerges: [String: PRStatus] = [:]

    /// How long a listed pull request's status is kept before it is read again.
    static let pullRequestInterval: Duration = .seconds(300)

    func forgetPullRequests() {
        (pullRequests, pullRequestsReadAt, unwrittenMerges, syncing) = ([:], [:], [:], false)
    }
}

/// Reads the list. Listing a project must not replay every log (they can be megabytes): a thread's age is its first line, read once,
/// and its state is replayed only for the threads shown and only when its log or goal file changed.
enum ThreadListLoader {
    static let maxRows = 50

    /// Size and modification time of each thread's log and goal file: what a poll compares.
    struct Signature: Equatable, Sendable {
        var files: [String: [String]]
    }

    static func signature(project: Project) -> Signature {
        let store = ThreadStore(project: project)
        var files: [String: [String]] = [:]
        for id in store.threadIDs() {
            files[id] = [fingerprint(project.eventsURL(id)), fingerprint(project.goalURL(id))]
        }
        return Signature(files: files)
    }

    private static func fingerprint(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? -1)@\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    /// Remembers what was read, so a second listing with nothing changed reads nothing.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [String: String] = [:]
        private var rows: [String: (print: [String], row: ThreadRow)] = [:]

        func createdAt(_ id: String, read: () -> String) -> String {
            if let known = lock.withLock({ created[id] }) { return known }
            let value = read()
            lock.withLock { created[id] = value }
            return value
        }

        func row(_ id: String, print: [String]) -> ThreadRow? {
            lock.withLock { rows[id].flatMap { $0.print == print ? $0.row : nil } }
        }

        func remember(_ row: ThreadRow, print: [String]) { lock.withLock { rows[row.id] = (print, row) } }
        func forget(except ids: Set<String>) { lock.withLock { rows = rows.filter { ids.contains($0.key) } } }
    }

    /// `thread.created`'s time, from the log's first line alone (core's, shared with the rail's counts).
    static func firstLineCreatedAt(_ url: URL) -> String { ProjectSummaryLoader.firstLineCreatedAt(url) }

    /// - Parameter pullRequests: what GitHub said of each thread's pull request, when it was read; a thread missing here is derived
    ///   from its log alone, which never says merged.
    static func load(project: Project, cache: Cache, pullRequests: [String: PRStatus] = [:]) -> ThreadListing {
        let store = ThreadStore(project: project)
        let ids = store.threadIDs()
        let newestFirst = ids.map { id in (id, cache.createdAt(id) { firstLineCreatedAt(project.eventsURL(id)) }) }
            .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
        let shown = Array(newestFirst.prefix(maxRows)).map(\.0)
        cache.forget(except: Set(shown))
        let rows = shown.map { id -> ThreadRow in
            let status = pullRequests[id]
            let print = [fingerprint(project.eventsURL(id)), fingerprint(project.goalURL(id)), status.map { "\($0)" } ?? ""]
            if let known = cache.row(id, print: print) { return known }
            let fresh = row(project: project, store: store, id: id, pullRequest: status)
            cache.remember(fresh, print: print)
            return fresh
        }
        return ThreadListing(rows: rows, older: max(0, ids.count - shown.count))
    }

    /// The most of a goal file a row reads: a goal with a huge request is not allocated and parsed on every poll for its title.
    static let goalHeadBytes = 64 * 1024

    /// The head of a goal file, and whether that was all of it.
    static func goalHead(_ url: URL) -> (text: String, whole: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", true) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: goalHeadBytes + 1)) ?? Data()
        return (String(decoding: data.prefix(goalHeadBytes), as: UTF8.self), data.count <= goalHeadBytes)
    }

    /// The `title:` of the front matter of a goal too long to parse whole.
    static func frontMatterTitle(_ text: String) -> String? {
        let lines = text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: false).prefix(40)
        if let line = lines.first(where: { $0.hasPrefix("title:") }) {
            let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// A chat's name: the first line of what the person first said, else the thread's id.
    static func chatTitle(state: ThreadState, id: String) -> String {
        let first = state.chat?.messages.first { $0.role == .user }?.text ?? ""
        let words = first.split(whereSeparator: \.isNewline).first.map { String($0.prefix(60)) } ?? ""
        return words.trimmingCharacters(in: .whitespaces).isEmpty ? id : words
    }

    /// A chat thread's row: its first words, and grey while it waits, blue while a turn is going, over once it has ended.
    static func chatRow(id: String, state: ThreadState, damaged: Bool = false) -> ThreadRow {
        let title = chatTitle(state: state, id: id)
        let mark = ThreadMark(activity: .chat(state: state, damaged: damaged))
        if damaged { return ThreadRow(id: id, title: title, mark: mark, line: "The log cannot be read") }
        if let decision = state.decision { return ThreadRow(id: id, title: title, mark: mark, line: decision.capitalized) }
        if state.chat?.open == true { return ThreadRow(id: id, title: title, mark: mark, line: "Chat · replying") }
        return ThreadRow(id: id, title: title, mark: mark, line: "Chat")
    }

    /// One thread's row: its log replayed once, the way the toolbar's pill is derived, with what GitHub said of its pull request when
    /// that was read (`pullRequest`), the way the thread's own screen applies it.
    static func row(project: Project, store: ThreadStore, id: String, pullRequest status: PRStatus? = nil) -> ThreadRow {
        let contents: EventLogContents
        do { contents = try EventLogReader.read(at: project.eventsURL(id)) } catch {
            return ThreadRow(id: id, title: id, mark: .broken, line: "The log cannot be read")
        }
        if contents.events.isEmpty && !contents.problems.isEmpty {
            return ThreadRow(id: id, title: id, mark: .broken, line: "The log cannot be read")
        }
        let state = store.state(from: contents.events, id: id)
        // A chat has no goal file until one is made from it: its first words are its title, and its line says Chat.
        if state.isChat, !FileManager.default.fileExists(atPath: project.goalURL(id).path) {
            return chatRow(id: id, state: state, damaged: !contents.problems.isEmpty)
        }
        var title: String?
        var approval: ApprovalState?
        let (text, whole) = goalHead(project.goalURL(id))
        if whole, let goal = try? GoalFile.parse(text).goal {
            (title, approval) = (goal.title, goal.approval)
        } else {
            // Too long to parse from its head: the title is in the front matter, and the log says whether it was ever approved
            // (an edit since is not seen here; opening the thread shows it).
            title = frontMatterTitle(text)
            approval = state.approvedGoalHash != nil ? .approved : .draft
        }
        // Only a status read for the pull request the log names counts: one for an earlier number says nothing of this one.
        let recorded = state.pullRequest
        let status = status.flatMap { $0.number == recorded?.number ? $0 : nil }
        // A merge the log recorded needs no read of GitHub.
        let outcome = state.isMerged ? PullRequestOutcome.merged : outcome(status)
        let checks = status?.checksError == nil ? status?.checks : nil
        let spine = ThreadSpine.derive(
            state: state, approval: approval, outcome: outcome, checks: checks, currentHead: status?.head)
        let attention = Attention.derive(
            spine: spine, state: state, checks: checks, outcome: outcome, currentHead: status?.head)
        let mark = mark(attention: attention, state: state, damaged: !contents.problems.isEmpty, outcome: outcome)
        var line = ThreadSnapshot.stateText(attention: attention, state: state, approval: approval)
        if let recorded, outcome != .open { line = "PR #\(recorded.number) \(outcome == .merged ? "merged" : "closed")" }
        let unsettled = state.decision == "accepted" && !state.cleaned && outcome == .open
        return ThreadRow(
            id: id, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? id, mark: mark, line: line,
            pullRequest: unsettled ? recorded?.number : nil)
    }

    /// What GitHub said became of the pull request; open when nothing was read, so a merge is only ever one GitHub confirmed.
    static func outcome(_ status: PRStatus?) -> PullRequestOutcome {
        switch status?.state {
        case .merged?: .merged
        case .closed?: .closed
        case .open?, nil: .open
        }
    }

    /// Amber for a thread that needs you, blue for one working, green for one that is over and done, grey for the rest, red for a broken log.
    static func mark(
        attention: Attention, state: ThreadState, damaged: Bool, outcome: PullRequestOutcome = .open
    ) -> ThreadMark {
        // The rule is core's (`ThreadActivity`), shared with the project rail's counts.
        ThreadMark(activity: .classify(attention: attention, state: state, damaged: damaged, outcome: outcome))
    }
}
