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
        if !run.units.isEmpty { out.append("units:    \(run.units.joined(separator: ", "))") }
        if let thread = run.thread { out.append("thread:   \(thread)") }
        if let url = run.pullRequest { out.append("pull request: \(url)") }
        if let reason = run.reason { out.append("reason:   \(reason)") }
        if let thread = run.thread, SafeNames.isThreadID(thread) { out += threadLines(project: project, thread: thread) }
        return out
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60)m\(total % 60)s" : "\(total)s"
    }

    /// Setup, check and the agent's last message, from the thread's own log.
    static func threadLines(project: Project, thread: String) -> [String] {
        guard FileManager.default.fileExists(atPath: project.eventsURL(thread).path),
            let events = try? EventLogReader.read(at: project.eventsURL(thread)).events
        else { return ["thread log: not found (the thread was removed)"] }
        var out: [String] = []
        if let setup = events.last(where: { $0.kind == .setupRan }) {
            let secs = (setup.data["duration_ms"]?.intValue).map { " (\($0 / 1000)s)" } ?? ""
            out.append("setup:    \(setup.data["result"]?.stringValue ?? "?")\(secs)")
        }
        if let check = events.last(where: { $0.kind == .checkRan }) {
            let result = check.data["result"]?.stringValue ?? "?"
            let secs = (check.data["duration_ms"]?.intValue).map { " (\($0 / 1000)s)" } ?? ""
            out.append("check:    \(result)\(secs)")
            if result != "passed", let ref = check.data["output_ref"]?.stringValue,
                let data = try? Data(contentsOf: project.threadDirectory(thread).appendingPathComponent(ref)) {
                let tail = String(decoding: data.suffix(8 << 10), as: UTF8.self).split(separator: "\n")
                    .suffix(TaskExplanation.maxCheckLines)
                for line in tail {
                    out.append("          " + TaskExplanation.clean(String(line), limit: TaskExplanation.maxCheckLine))
                }
            }
        }
        let denied = events.filter { $0.kind == .agentActivity && $0.data["type"]?.stringValue == "permission_denied" }.count
        if denied > 0 { out.append("denied:   \(denied) tool call(s): `workbench grant \(thread)` lists them") }
        if let said = events.last(where: { $0.kind == .agentActivity && $0.data["type"]?.stringValue == "text" }),
            let text = said.data["text"]?.stringValue {
            out.append("agent:    \(TaskExplanation.clean(text, limit: TaskExplanation.maxMessage))")
        }
        return out
    }
}
