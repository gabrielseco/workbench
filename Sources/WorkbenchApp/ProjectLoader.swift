import Foundation
import WorkbenchCore

/// Reads a project from disk and derives what the window shows. Pure of UI and of the main actor: the store calls it from a
/// background task, and the tests call it directly.
enum ProjectLoader {
    /// What changing means for the window: when none of these moved since the last look, nothing is read again.
    struct Watch: Equatable {
        var threadsDirectory: Date?
        var logSize: Int?
        var logModified: Date?
        var goalModified: Date?
        var configModified: Date?
    }

    static func watch(project: Project, thread: String?) -> Watch {
        func attributes(_ url: URL) -> (size: Int?, modified: Date?) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (values?.fileSize, values?.contentModificationDate)
        }
        var watch = Watch(threadsDirectory: attributes(project.threadsDirectory).modified)
        watch.configModified = attributes(project.configURL).modified
        if let thread {
            let log = attributes(project.eventsURL(thread))
            (watch.logSize, watch.logModified) = (log.size, log.modified)
            watch.goalModified = attributes(project.goalURL(thread)).modified
        }
        return watch
    }

    /// The thread the app shows: the active one, else the newest that is not cleaned, else the newest.
    static func currentThread(store: ThreadStore) -> String? {
        if let active = store.activeThreadID() { return active }
        let newestFirst = store.summaries().sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        return newestFirst.first { !store.state(of: $0.id).cleaned }?.id ?? newestFirst.first?.id
    }

    /// What one full read of the project found, and what `stat` said just before the log was read.
    struct Loaded: Sendable {
        var screen: ProjectScreen
        var thread: String?
        var watch: Watch
    }

    /// The `stat` snapshot is taken before the log is read: a write that lands during the read makes the log differ from
    /// the snapshot, so the next poll reads again. Taken after, it would describe the new file with the old screen and the
    /// write would be missed for good.
    /// `afterRead` runs right after the log was read: a test writes to the log there, as a runner would in that instant.
    static func load(project: Project, afterRead: @Sendable () -> Void = {}) -> Loaded {
        let folders = watch(project: project, thread: nil)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.workbenchDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return Loaded(screen: .workbenchMissing(path: project.root.path), thread: nil, watch: folders) }
        let store = ThreadStore(project: project)
        guard let id = currentThread(store: store) else { return Loaded(screen: .noThread, thread: nil, watch: folders) }
        var seen = watch(project: project, thread: id)
        seen.threadsDirectory = folders.threadsDirectory
        let screen = snapshot(project: project, store: store, id: id)
        afterRead()
        return Loaded(screen: screen, thread: id, watch: seen)
    }

    static func snapshot(project: Project, store: ThreadStore, id: String) -> ProjectScreen {
        let log = project.eventsURL(id)
        let contents: EventLogContents
        do { contents = try EventLogReader.read(at: log) } catch {
            if case EventLogError.io(let message) = error { return .logCorrupt(thread: id, problems: [message]) }
            return .logCorrupt(thread: id, problems: ["\(error)"])
        }
        // A log with some damaged lines still shows what it has, as `status` does; one with nothing readable cannot.
        if contents.events.isEmpty && !contents.problems.isEmpty {
            return .logCorrupt(thread: id, problems: contents.problems.prefix(3).map(describe))
        }
        let state = store.state(from: contents.events, id: id)
        var title: String?
        var base: String?
        var approval: ApprovalState?
        var budget: Decimal?
        let text = try? String(contentsOf: project.goalURL(id), encoding: .utf8)
        if let text, let goal = try? GoalFile.parse(text).goal {
            (title, base, approval, budget) = (goal.title, goal.base, goal.approval, goal.budgetUSD)
        }
        let spine = ThreadSpine.derive(state: state, approval: approval)
        return .thread(
            ThreadSnapshot(
                id: id, title: title, base: base, approval: approval, budgetUSD: budget, state: state, spine: spine,
                attention: Attention.derive(spine: spine, state: state), lastSeq: contents.events.last?.seq ?? 0,
                logURL: log, problems: contents.problems.prefix(3).map(describe)))
    }

    /// A damaged line in words a person can act on.
    static func describe(_ problem: LogProblem) -> String {
        switch problem {
        case .invalidLine(let line): "line \(line) is not a valid event"
        case .seqMismatch(let expected, let found, let line): "line \(line) has seq \(found), expected \(expected)"
        case .turnStartedWhileOpen(let turn, let open, let line): "line \(line) starts turn \(turn) while turn \(open) is open"
        case .turnNotConsecutive(let expected, let found, let line): "line \(line) is turn \(found), expected \(expected)"
        case .turnEndedWithoutStart(let turn, let line): "line \(line) ends turn \(turn), which was not open"
        case .activityOutsideTurn(let turn, let line): "line \(line) is activity of turn \(turn) outside a turn"
        case .checkStartedWhileOpen(let turn, let open, let line):
            "line \(line) starts the check of turn \(turn) while turn \(open)'s is open"
        case .checkRanWithoutStart(let turn, let line): "line \(line) is the check of turn \(turn), which was not started"
        }
    }
}
