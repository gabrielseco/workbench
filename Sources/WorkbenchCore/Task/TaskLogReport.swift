import Foundation

/// `workbench task log`: what a task's runs did, in words, from the task's own log and the threads it started. Read only.
public enum TaskLogReport {
    /// The last run of a task, or every run in one line each.
    public static func lines(
        project: Project, name: String, all: Bool = false, timeZone: TimeZone = .current
    ) throws -> [String] {
        let history = try TaskRunLog(project: project, name: name).history()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard !history.runs.isEmpty else { return ["\(name) has never run."] }
        if all {
            return history.runs.map { run in
                let outcome = run.outcome?.rawValue ?? "running"
                let units = run.units.isEmpty ? "" : "  " + run.units.joined(separator: ",")
                let why = run.reason.map { "  " + TaskExplanation.clean($0, limit: 100) } ?? ""
                return "\(format.string(from: run.started))  \(run.trigger)  \(outcome)\(units)\(why)"
            }
        }
        guard let run = history.runs.last else { return [] }
        var out = ["\(name)  run \(history.runs.count) of \(history.runs.count)"]
        out.append("started:  \(format.string(from: run.started))  (\(run.trigger))")
        if let ended = run.ended {
            out.append("ended:    \(format.string(from: ended))  (\(duration(ended.timeIntervalSince(run.started))))")
        } else {
            out.append("ended:    not yet (the run is going, or its process died: the next run closes it)")
        }
        out.append("outcome:  \(run.outcome?.rawValue ?? "running")")
        if let tools = try? TaskLibrary(project: project).load(name).definition.mcpTools, !tools.isEmpty {
            out.append("mcp:      may call \(tools.joined(separator: ", ")) (the task file now; runs without --safe-mode)")
        }
        if !run.units.isEmpty { out.append("units:    \(run.units.joined(separator: ", "))") }
        if let thread = run.thread { out.append("thread:   \(thread)") }
        if let url = run.pullRequest { out.append("pull request: \(url)") }
        // Stored reasons are cleaned again on the way out: an older record, or one written by something else, is still text from outside.
        if let reason = run.reason { out.append("reason:   " + TaskExplanation.clean(reason, limit: TaskExplanation.maxReason)) }
        if let thread = run.thread, SafeNames.isThreadID(thread) { out += threadLines(project: project, thread: thread) }
        return out
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60)m\(total % 60)s" : "\(total)s"
    }

    /// Setup, check and the agent's last message, from the thread's own log.
    static func threadLines(project: Project, thread: String) -> [String] {
        let detail = TaskRunDetail.read(project: project, thread: thread)
        guard detail.source == .read else { return ["thread log: not found (the thread was removed)"] }
        var out: [String] = []
        func seconds(_ value: Int?) -> String { value.map { " (\($0)s)" } ?? "" }
        if let setup = detail.setup { out.append("setup:    \(setup.result)\(seconds(setup.seconds))") }
        if let check = detail.check {
            out.append("check:    \(check.result)\(seconds(check.seconds))")
            for line in check.tail { out.append("          " + line) }
        }
        if detail.denied > 0 { out.append("denied:   \(detail.denied) tool call(s): `workbench grant \(thread)` lists them") }
        if let text = detail.agentMessage { out.append("agent:    \(text)") }
        return out
    }

    /// What the agent said last. The turn's own summary is the final answer; failing that the transcript, which keeps every line;
    /// failing that the streamed events, which stop at 1000 per turn and can end before the last thing said.
    static func lastAgentText(project: Project, thread: String, events given: [Event]?) -> String? {
        guard SafeNames.isThreadID(thread) else { return nil }
        guard let events = given ?? (try? EventLogReader.read(at: project.eventsURL(thread)).events) else { return nil }
        if let summary = events.last(where: { $0.kind == .turnEnded && $0.data["summary"]?.stringValue != nil })?
            .data["summary"]?.stringValue, !summary.isEmpty {
            return summary
        }
        if let turn = events.last(where: { $0.kind == .turnStarted })?.turn, turn > 0 {
            let lines = TranscriptFile.lines(at: TranscriptFile.url(in: project.threadDirectory(thread), turn: turn))
            for line in lines.reversed() where line["type"]?.stringValue == "assistant" {
                guard case .array(let parts)? = line["message"]?["content"] else { continue }
                if let text = parts.reversed().first(where: { $0["type"]?.stringValue == "text" })?["text"]?.stringValue,
                    !text.isEmpty {
                    return text
                }
            }
        }
        return events.last(where: { $0.kind == .agentActivity && $0.data["type"]?.stringValue == "text" })?
            .data["text"]?.stringValue
    }
}
