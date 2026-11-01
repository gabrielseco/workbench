import Foundation

/// A `fix: report` run: one read-only turn that reads the project as it is committed and answers with a report. It starts no thread,
/// changes nothing and opens nothing; the answer is kept under the task as a file and the run says in one line what it found.
extension TaskRunner {
    /// The most of a report kept in a file; the agent's answer is cut there.
    public static let maxReportBytes = 256 << 10
    /// Minutes a report turn may take when the task does not say.
    static let defaultReportTimeoutMin = 30

    func runReport(name: String, loaded: LoadedTask, units: [TaskUnit]) async -> TaskRunResult {
        let task = loaded.definition
        let ids = units.map(\.id)
        func failed(_ why: String) -> TaskRunResult { TaskRunResult(outcome: .failed, reason: why, units: ids) }

        let config: Config
        do { config = try Config.load(from: project.configURL) } catch {
            return failed("the project's config cannot be read: \(error)")
        }
        let prompt: String
        do {
            let inputs = try TaskFiles(project: project).inputs(task.inputs)
            prompt = try TaskPrompt.build(task: loaded, inputs: inputs, units: units, deliverable: .report)
        } catch { return failed("\(error)") }
        if let why = await freshBase(task) { return failed(why) }

        // The turn reads the base as committed, in a checkout of its own: not the working tree, which may hold what is not committed.
        let service = ThreadService(project: project, git: git)
        let baseName: String
        if let base = task.base { baseName = base } else { baseName = await service.defaultBase() }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        let commit: String
        do { commit = try await manager.commit(of: baseName) } catch {
            return failed("the base \(baseName) cannot be read: \(error)")
        }

        let agent = config.resolvedPlanAgent()
        let budget = task.budgetUSD ?? config.defaultBudgetUSD
        let folder = project.taskDirectory(name).appendingPathComponent("report", isDirectory: true)
        let checkout = folder.appendingPathComponent("checkout", isDirectory: true)
        let key = Plan.sha256(folder.standardizedFileURL.path).prefix(16)
        let scratch = TurnScratch(url: FileManager.default.temporaryDirectory.appendingPathComponent("workbench-report-\(key)"))
        let request = ReadOnlyRequest(
            prompt: prompt, workingDirectory: checkout, model: agent.model, budget: budget,
            timeout: TimeInterval((task.timeoutMin ?? Self.defaultReportTimeoutMin) * 60),
            reasoningEffort: agent.reasoningEffort, tools: .read, scratch: scratch, turn: "report")
        let chosen: any ReadOnlyAgent
        if let given = readOnlyAgent {
            chosen = given
        } else {
            switch ThreadService.readOnlyAgent(role: .plan, agent: agent, config: config, cap: budget, environment: environment) {
            case .success(let found): chosen = found
            case .failure(let refusal): return failed(refusal.message)
            }
        }
        if let why = chosen.unavailable() { return failed(why) }

        OrphanSweeper.sweep(inside: folder)
        await manager.removeDetached(at: checkout)
        scratch.clear()
        let stop = self.stop
        let answer: ReadOnlyAnswer
        do {
            try await manager.addDetached(at: checkout, commit: commit)
            answer = await chosen.run(request, attach: { stop.attach(process: $0) })
        } catch {
            OrphanSweeper.sweep(inside: folder)
            scratch.clear()
            await manager.removeDetached(at: checkout)
            return failed("the base could not be checked out for the report: \(error)")
        }
        OrphanSweeper.sweep(inside: folder)
        scratch.clear()
        let cleaned = await manager.removeDetached(at: checkout)

        guard let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            let why = answer.failure ?? "the agent gave no answer"
            return failed(cleaned ? why : why + "; the report's checkout could not be removed, the next run clears it")
        }
        let body = Self.report(text)
        let file: URL
        do { file = try Self.write(report: body.text, task: name, project: project, at: now()) } catch {
            return failed("the report could not be saved: \(error)")
        }
        let first = body.text.split(whereSeparator: \.isNewline).first.map { Self.headline(String($0)) } ?? ""
        let saved = file.path.replacingOccurrences(of: project.root.path + "/", with: "")
        var reason = (first.isEmpty ? "report written" : first) + " (\(saved))"
        if body.cut { reason += "; the answer was cut at \(Self.maxReportBytes / 1024) KiB" }
        return TaskRunResult(outcome: .reported, reason: reason, units: ids)
    }

    /// The answer as kept: bounded, with no NUL.
    static func report(_ text: String) -> (text: String, cut: Bool) {
        let clean = text.replacingOccurrences(of: "\0", with: "")
        guard clean.utf8.count > maxReportBytes else { return (clean, false) }
        return (String(decoding: clean.utf8.prefix(maxReportBytes), as: UTF8.self), true)
    }

    /// A Markdown heading mark in front of the first line is not part of what it says.
    static func headline(_ line: String) -> String {
        TaskExplanation.clean(String(line.drop { $0 == "#" || $0 == " " }), limit: 200)
    }

    /// `.workbench/tasks/<name>/reports/<time>.md`, a name no earlier report has.
    static func write(report: String, task: String, project: Project, at date: Date) throws -> URL {
        let folder = project.taskDirectory(task).appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd-HHmmss"
        let stem = format.string(from: date)
        var url = folder.appendingPathComponent("\(stem).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem)-\(n).md")
            n += 1
        }
        try Data((report + "\n").utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
}
