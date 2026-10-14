import Foundation
import WorkbenchCore

/// The read side: log, status, review.
extension Commands {
    static func log(_ args: [String]) async throws {
        var a = Arguments(args)
        let follow = a.flag("--follow", "-f")
        let verbose = a.flag("--verbose", "-v", "--raw")
        let seqText = try a.value("--seq")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        let url = ctx.project.eventsURL(id)

        if let seqText {
            try showEvent(seqText, in: id, url: url)
            return
        }

        // `--json`: the stored lines themselves, one event each, nothing added.
        if Output.json {
            var written = 0
            func rawLines() -> [String] {
                // Split as bytes: a writer that died inside a multibyte character must not hide the whole
                // events before it.
                let data = (try? Data(contentsOf: url)) ?? Data()
                var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
                _ = parts.popLast()  // the part after the last newline is not a whole event yet
                return parts.map { String(decoding: $0, as: UTF8.self) }
            }
            var contents = try EventLogReader.read(at: url)
            for line in rawLines() {
                out(line)
                written += 1
            }
            guard follow else { return }
            let checks = (try? Config.load(from: ctx.project.configURL))?.checkCommand != nil
            var sawStart = contents.openTurn != nil || contents.openCheck != nil
            var seen = contents.events.count
            while true {
                try await Task.sleep(nanoseconds: 300_000_000)
                contents = try EventLogReader.read(at: url)
                let lines = rawLines()
                for line in lines.dropFirst(written) { out(line) }
                written = lines.count
                for event in contents.events.dropFirst(seen) {
                    if event.kind == .turnStarted { sawStart = true }
                    let result = event.data["result"]?.stringValue
                    let checkFollows = checks && result != "stopped" && result != "interrupted"
                    if event.kind == .turnEnded, sawStart, !checkFollows { return }
                    if event.kind == .checkRan, sawStart { return }
                }
                seen = contents.events.count
            }
        }

        func show(_ event: Event) {
            if event.kind == .claude, !verbose, LogFormatter.describeClaude(event.data) == nil { return }
            // One line per check: how it ended.
            if event.kind == .checkStarted, !verbose { return }
            out(LogFormatter.describe(event))
        }

        var printed = 0
        var contents = try EventLogReader.read(at: url)
        // Already in the middle of a turn or of its check: follow until that ends.
        let startedWithOpenTurn = contents.openTurn != nil || contents.openCheck != nil
        for event in contents.events {
            show(event)
            printed += 1
        }
        guard follow else { return }

        // A turn is followed to the end of its check, when one will run.
        let checks = (try? Config.load(from: ctx.project.configURL))?.checkCommand != nil
        var sawStart = startedWithOpenTurn
        while true {
            try await Task.sleep(nanoseconds: 300_000_000)
            contents = try EventLogReader.read(at: url)
            for event in contents.events.dropFirst(printed) {
                show(event)
                if event.kind == .turnStarted { sawStart = true }
                let result = event.data["result"]?.stringValue
                let checkFollows = checks && result != "stopped" && result != "interrupted"
                if event.kind == .turnEnded, sawStart, !checkFollows { return }
                if event.kind == .checkRan, sawStart { return }
            }
            printed = contents.events.count
        }
    }

    static func status(_ args: [String]) async throws {
        var a = Arguments(args)
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()

        // A named thread that does not exist is an error; only "no threads at all" is a friendly line.
        if named != nil { _ = try ctx.threadIDForViewing(named) }
        guard let id = try? ctx.threadIDForViewing(named) else {
            if Output.json { throw CLIError.notFound("no threads yet. Start one: workbench goal new <name>") }
            out("no threads yet. Start one: workbench goal new <name>")
            return
        }
        if Output.json {
            printJSON(await statusJSON(id: id, ctx: ctx))
            return
        }
        let state = ctx.store.state(of: id)
        out("thread:    \(id)\(state.isActive ? "" : "  (ended: \(state.decision ?? "?"))")")

        if let text = try? String(contentsOf: ctx.project.goalURL(id), encoding: .utf8) {
            do {
                let goal = try GoalFile.parse(text).goal
                out("title:     \(goal.title)")
                let approval: String
                switch goal.approval {
                case .approved: approval = "approved"
                case .draft: approval = "draft (run `workbench goal approve`)"
                case .stale: approval = "CHANGED since approval, back to draft (run `workbench goal approve`)"
                }
                out("goal:      \(approval)")
                out("base:      \(goal.base)   budget $\(goal.budgetUSD)/turn   timeout \(goal.turnTimeoutMin) min")
                if let line = await baseGapLine(goal.base, ctx: ctx) { out("           \(line)") }
            } catch let error as GoalParseError {
                let problems = error.description.split(separator: "\n").map { "           \($0)" }
                out("goal:      not valid\n\(problems.joined(separator: "\n"))")
            }
        }

        let running = ctx.service.runnerPID(id: id) != nil
        var turns = "turns:     \(state.lastTurn)"
        if let open = state.openTurn {
            let note = running ? "running" : "NOT running: will be recorded as interrupted on next run"
            turns += "  (turn \(open) open, \(note))"
        }
        out(turns)
        if let result = state.lastResult { out("last turn: \(result)") }
        if let open = state.openCheck {
            let note = running ? "running" : "NOT running: will be recorded as interrupted on next run"
            out("check:     turn \(open) open, \(note)")
        } else if let check = state.lastCheck {
            out("check:     \(check)")
        }
        if state.openTurn != nil {
            for line in state.progress.lines(timeout: turnTimeout(id: id, ctx: ctx), now: Date()) { out(line) }
        }
        out(String(format: "cost:      $%.4f (list price; not what a subscription charges)", state.totalCostUSD))
        if state.openTurn != nil { out("           the open turn's cost is reported when it ends") }
        for note in state.review.notes { out("note:      turn \(note.turn): " + ReviewReport.oneLine(note.text)) }
        let worktree = ctx.project.worktreesDirectory.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: worktree.path) {
            out("worktree:  \(worktree.path)")
        } else if let events = try? EventLogReader.read(at: ctx.project.eventsURL(id)).events,
            events.contains(where: { $0.kind == .worktreeRemoved }) {
            out("worktree:  removed after shipping (branch \(WorktreeManager.branch(for: id)) is kept)")
        }
    }

    /// The goal's per-turn limit in seconds, nil when the goal cannot be read.
    static func turnTimeout(id: String, ctx: Context) -> TimeInterval? {
        guard let text = try? String(contentsOf: ctx.project.goalURL(id), encoding: .utf8),
            let goal = try? GoalFile.parse(text).goal
        else { return nil }
        return TimeInterval(goal.turnTimeoutMin * 60)
    }

    static func review(_ args: [String]) async throws {
        var a = Arguments(args)
        let patch = try a.value("--patch")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        if named == nil, ctx.store.threadIDs().isEmpty {
            if Output.json { throw CLIError.notFound("no threads yet. Start one: workbench goal new <name>") }
            out("no threads yet. Start one: workbench goal new <name>")
            return
        }
        let id = try ctx.threadIDForViewing(named)
        let loader = ReviewLoader(project: ctx.project, git: ctx.git)
        if let patch {
            guard let shown = try await loader.patch(id: id, path: patch) else {
                throw CLIError.notFound("'\(patch)' is not in the diff of \(id) (see `workbench review`)")
            }
            if Output.json {
                printJSON(patchJSON(path: patch, patch: shown))
            } else {
                out(ReviewReport.render(shown))
            }
            return
        }
        let report = await loader.load(id: id)
        if Output.json {
            printJSON(await reviewJSON(report, ctx: ctx))
            return
        }
        for line in report.render() { out(line) }
        if let text = try? String(contentsOf: ctx.project.goalURL(id), encoding: .utf8),
            let goal = try? GoalFile.parse(text).goal, let line = await baseGapLine(goal.base, ctx: ctx) {
            out("")
            out("Base       \(line)")
        }
    }

    /// One line when the base branch is behind its origin counterpart or could not be compared; nil when
    /// there is nothing to say. Fetches that one branch, bounded; offline is a note, not an error.
    static func baseGapLine(_ base: String, ctx: Context) async -> String? {
        let manager = WorktreeManager(repoRoot: ctx.project.root, git: ctx.git)
        guard let gap = await manager.baseGap(base: base) else { return nil }
        var parts: [String] = []
        if gap.behind > 0 {
            parts.append("\(base) is \(gap.behind) commit\(gap.behind == 1 ? "" : "s") behind origin/\(base)")
        }
        if let note = gap.fetchNote { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
