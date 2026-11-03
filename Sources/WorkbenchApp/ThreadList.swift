import Foundation
import Observation
import WorkbenchCore

/// What a thread's row says: the mark carries the colour and the symbol, the line says it in words.
enum ThreadMark: String, Equatable, Sendable {
    case working, needsYou, done, idle, broken
}

struct ThreadRow: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var mark: ThreadMark
    /// One line of state, in the toolbar pill's words.
    var line: String
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

    /// `thread.created`'s time, from the log's first line alone; "" when it cannot be told (the thread sorts last).
    static func firstLineCreatedAt(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8_192)) ?? Data()
        guard let line = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
            let event = try? JSONDecoder().decode(Event.self, from: Data(line))
        else { return "" }
        return event.ts
    }

    static func load(project: Project, cache: Cache) -> ThreadListing {
        let store = ThreadStore(project: project)
        let ids = store.threadIDs()
        let newestFirst = ids.map { id in (id, cache.createdAt(id) { firstLineCreatedAt(project.eventsURL(id)) }) }
            .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
        let shown = Array(newestFirst.prefix(maxRows)).map(\.0)
        cache.forget(except: Set(shown))
        let rows = shown.map { id -> ThreadRow in
            let print = [fingerprint(project.eventsURL(id)), fingerprint(project.goalURL(id))]
            if let known = cache.row(id, print: print) { return known }
            let fresh = row(project: project, store: store, id: id)
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
    static func chatRow(id: String, state: ThreadState) -> ThreadRow {
        let title = chatTitle(state: state, id: id)
        if let decision = state.decision { return ThreadRow(id: id, title: title, mark: .idle, line: decision.capitalized) }
        if state.chat?.open == true { return ThreadRow(id: id, title: title, mark: .working, line: "Chat · replying") }
        return ThreadRow(id: id, title: title, mark: .idle, line: "Chat")
    }

    /// One thread's row: its log replayed once, the way the toolbar's pill is derived.
    static func row(project: Project, store: ThreadStore, id: String) -> ThreadRow {
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
            return chatRow(id: id, state: state)
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
        let spine = ThreadSpine.derive(state: state, approval: approval)
        let attention = Attention.derive(spine: spine, state: state)
        let mark = mark(attention: attention, state: state, damaged: !contents.problems.isEmpty)
        let line = ThreadSnapshot.stateText(attention: attention, state: state, approval: approval)
        return ThreadRow(id: id, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? id, mark: mark, line: line)
    }

    /// Amber for a thread that needs you, blue for one working, green for one that is over and done, grey for the rest, red for a broken log.
    static func mark(attention: Attention, state: ThreadState, damaged: Bool) -> ThreadMark {
        if damaged { return .broken }
        if case .needsYou = attention { return .needsYou }
        if attention == .working { return .working }
        // Green is for work that went somewhere; a thread thrown away is just over.
        if state.decision == "discarded" { return .idle }
        if state.cleaned || state.pullRequest != nil || state.decision != nil { return .done }
        return .idle
    }
}
