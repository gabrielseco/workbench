import Foundation

/// Why a quick goal was not made. Nothing was written or abandoned.
public enum QuickGoalRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyRequest
    case requestTooLong
    /// A line of the request would start a section of the goal file.
    case heading(String)
    case invalidName(String)
    case activeThread(String)
    case doctorRunning
    case attachment(String)
    /// The request does not read back from a goal file as written.
    case notKept(String)

    public var description: String {
        switch self {
        case .emptyRequest: "the request is empty: say what should be done."
        case .requestTooLong: "the request is over \(GoalDraft.requestLimit / 1024) KiB; shorten it."
        case .heading(let line):
            "a line of the request starts a section of the goal file ('\(line)'); indent it or reword it."
        case .invalidName(let name): "'\(name)' is not a usable thread name: letters, digits, '.', '_' and '-' only."
        case .activeThread(let id): "thread \(id) is still active: finish or abandon it first (one thread at a time)."
        case .doctorRunning: "`workbench doctor` is running; try again when it ends."
        case .attachment(let why): why
        case .notKept(let why): "the request could not be kept as written: \(why)"
        }
    }
}

/// A goal made from the request alone: no agent drafts it, so it costs nothing and the words are the person's. It is marked
/// `quick: true` and has no criteria, which leaves out the steps that report on them (the judge, the verifier).
public enum QuickGoal {
    public static let titleLimit = 72

    /// The request's first line that has words, cut at a word under `titleLimit`; nil when none can be a title.
    public static func title(from request: String) -> String? {
        guard
            let line = request.split(whereSeparator: \.isNewline).lazy
                .map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }).first(where: { !$0.isEmpty })
        else { return nil }
        var title = line
        if title.count > titleLimit {
            let cut = String(title.prefix(titleLimit))
            let atWord = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
            title = (atWord.isEmpty ? cut : atWord) + "…"
        }
        return FrontMatterLine.canRender(title) ? title : nil
    }

    /// The request as the goal keeps it: trimmed, line endings made `\n`, and refused (not changed) where a goal file could not
    /// hold it as written.
    static func request(_ raw: String) throws -> String {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw QuickGoalRefusal.emptyRequest }
        guard text.utf8.count <= GoalDraft.requestLimit, !text.contains("\0") else { throw QuickGoalRefusal.requestTooLong }
        if let heading = text.split(separator: "\n").first(where: { $0.hasPrefix("## ") }) {
            throw QuickGoalRefusal.heading(String(heading.prefix(80)))
        }
        return text
    }

    static func body(request: String) -> GoalBody { GoalBody(request: request, criteria: [], outOfScope: []) }

    /// The body under an ordinary quick front matter must come back from the goal parser as the same request.
    static func readsBack(_ body: GoalBody, title: String) throws {
        let text =
            "---\nid: quick\n\(FrontMatterLine(key: "title", value: title).rendered)\nbase: main\nbudget_usd: 1\n"
            + "turn_timeout_min: 30\nquick: true\n---\n\n\n" + body.rendered + "\n"
        let goal: Goal
        do { goal = try GoalFile.parse(text).goal } catch { throw QuickGoalRefusal.notKept("\(error)") }
        guard goal.request == body.request, goal.criteria.isEmpty, goal.title == title else {
            throw QuickGoalRefusal.notKept("it does not read back as the same words")
        }
    }
}

extension ThreadService {
    /// Writes a draft quick goal from `request` as a new thread named `name`, and returns its id. Nothing is spawned or spent. The
    /// screenshots are kept with the thread, as a drafted goal's are. With `abandonActive` the thread that is active is
    /// abandoned first (its changes saved as for `abandon`); without it an active thread refuses.
    public func newQuickGoal(
        name: String, request raw: String, base: String? = nil, config: Config? = nil, attachments urls: [URL] = [],
        abandonActive: Bool = false
    ) async throws -> String {
        guard SafeNames.isThreadID(name) else { throw QuickGoalRefusal.invalidName(name) }
        var request = try QuickGoal.request(raw)
        let title = QuickGoal.title(from: request) ?? name.replacingOccurrences(of: "-", with: " ")
        var images: [GoalAttachments.Loaded] = []
        if !urls.isEmpty {
            do { images = try GoalAttachments.load(urls) } catch { throw QuickGoalRefusal.attachment("\(error)") }
            request += "\n\n" + GoalAttachments.markdown(GoalAttachments.names(images))
        }
        let body = QuickGoal.body(request: request)
        try QuickGoal.readsBack(body, title: title)
        let store = ThreadStore(project: project)
        do { try store.requireNoDoctor() } catch { throw QuickGoalRefusal.doctorRunning }
        if let active = store.activeThreadID() {
            guard abandonActive else { throw QuickGoalRefusal.activeThread(active) }
            try await abandon(id: active)
        }
        let made = QuickThread()
        do {
            return try await newThread(
                name: name, base: base, config: config, body: body, settings: GoalSettings(quick: true), title: title
            ) { [images] id, _ in
                made.id = id
                guard !images.isEmpty else { return }
                let folder = self.project.threadDirectory(id).appendingPathComponent(GoalAttachments.folder, isDirectory: true)
                _ = try GoalAttachments.write(images, into: folder)
            }
        } catch {
            // A thread left half made would be an active draft that blocks the next one: only the one this call made goes.
            if let id = made.id { try? FileManager.default.removeItem(at: project.threadDirectory(id)) }
            throw error
        }
    }
}

private final class QuickThread: @unchecked Sendable {
    var id: String?
}
