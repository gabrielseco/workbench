import Foundation

/// What a run did, from the thread it made: how long, what it cost, how setup and the check went, what it was refused and what the agent
/// said last. One reader for `task log` and the app, so the two cannot disagree. Read only; every line of text is cleaned and bounded as a
/// reason is, because it comes from outside (the agent, the check's output).
public struct TaskRunDetail: Sendable, Equatable {
    /// Whether the run's thread could be read.
    public enum Source: Sendable, Equatable {
        /// The run made no thread (it was skipped, refused, or is a report run).
        case noThread
        /// It made one, and the thread's folder or log is gone (cleaned).
        case removed
        case read
    }

    public struct Step: Sendable, Equatable {
        public var result: String
        public var seconds: Int?

        public init(result: String, seconds: Int?) { (self.result, self.seconds) = (result, seconds) }
    }

    public struct Check: Sendable, Equatable {
        public var result: String
        public var seconds: Int?
        /// The end of the check's output, only when it did not pass: bounded in lines and in each line.
        public var tail: [String]

        public init(result: String, seconds: Int?, tail: [String]) {
            (self.result, self.seconds, self.tail) = (result, seconds, tail)
        }
    }

    public var source: Source
    /// From the run's start to its end; nil while it goes.
    public var duration: TimeInterval?
    /// The turns' costs added; nil when none reported one: an unknown cost is never shown as zero.
    public var costUSD: Double?
    public var setup: Step?
    public var check: Check?
    /// Tool calls refused: the turn's own record, or the streamed events if that is longer.
    public var denied: Int
    public var agentMessage: String?

    public init(
        source: Source, duration: TimeInterval? = nil, costUSD: Double? = nil, setup: Step? = nil, check: Check? = nil,
        denied: Int = 0, agentMessage: String? = nil
    ) {
        (self.source, self.duration, self.costUSD, self.setup) = (source, duration, costUSD, setup)
        (self.check, self.denied, self.agentMessage) = (check, denied, agentMessage)
    }

    /// The detail of one run of a task. A run that is still going has no duration and says what its thread has so far.
    public static func read(project: Project, run: TaskHistory.Run) -> TaskRunDetail {
        let duration = run.ended.map { $0.timeIntervalSince(run.started) }
        guard let thread = run.thread, SafeNames.isThreadID(thread) else {
            return TaskRunDetail(source: .noThread, duration: duration)
        }
        var detail = read(project: project, thread: thread)
        detail.duration = duration
        return detail
    }

    /// What a thread's own log says about the run that made it.
    static func read(project: Project, thread: String) -> TaskRunDetail {
        guard FileManager.default.fileExists(atPath: project.eventsURL(thread).path),
            let events = try? EventLogReader.read(at: project.eventsURL(thread)).events
        else { return TaskRunDetail(source: .removed) }
        var detail = TaskRunDetail(source: .read)
        if let setup = events.last(where: { $0.kind == .setupRan }) {
            detail.setup = Step(
                result: setup.data["result"]?.stringValue ?? "?", seconds: setup.data["duration_ms"]?.intValue.map { $0 / 1000 })
        }
        if let check = events.last(where: { $0.kind == .checkRan }) {
            let result = check.data["result"]?.stringValue ?? "?"
            var tail: [String] = []
            if result != "passed", let ref = check.data["output_ref"]?.stringValue,
                let data = try? Data(contentsOf: project.threadDirectory(thread).appendingPathComponent(ref)) {
                tail = String(decoding: data.suffix(8 << 10), as: UTF8.self).split(separator: "\n")
                    .suffix(TaskExplanation.maxCheckLines)
                    .map { TaskExplanation.clean(String($0), limit: TaskExplanation.maxCheckLine) }
            }
            detail.check = Check(result: result, seconds: check.data["duration_ms"]?.intValue.map { $0 / 1000 }, tail: tail)
        }
        let recorded = events.filter { $0.kind == .turnEnded }.reduce(0) { total, event in
            if case .array(let calls)? = event.data["denials"] { return total + calls.count }
            return total
        }
        let streamed = events.filter { $0.kind == .agentActivity && $0.data["type"]?.stringValue == "permission_denied" }.count
        detail.denied = max(recorded, streamed)
        for event in events where event.kind == .turnEnded {
            switch event.data["cost_usd"] {
            case .double(let value)?: detail.costUSD = (detail.costUSD ?? 0) + value
            case .int(let value)?: detail.costUSD = (detail.costUSD ?? 0) + Double(value)
            default: break
            }
        }
        if let text = TaskLogReport.lastAgentText(project: project, thread: thread, events: events) {
            detail.agentMessage = TaskExplanation.clean(text, limit: TaskExplanation.maxMessage)
        }
        return detail
    }
}
