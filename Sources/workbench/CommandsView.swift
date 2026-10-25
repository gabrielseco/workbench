import Foundation
import WorkbenchCore

/// The read side: log, status, review.
extension Commands {
    static func log(_ args: [String]) async throws {
        var a = Arguments(args)
        let follow = a.flag("--follow", "-f")
        let verbose = a.flag("--verbose", "-v", "--raw")
        let seqText = try a.value("--seq")
        let transcript = a.flag("--transcript")
        let turnText = try a.value("--turn")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        let url = ctx.project.eventsURL(id)

        if let seqText {
            try showEvent(seqText, in: id, url: url)
            return
        }

        // `--transcript`: what the agent printed, as stored, one stream line each. Nothing of Workbench's own.
        if transcript {
            if follow { throw CLIError.usage("log --transcript prints what is stored; it does not follow (use log -f)") }
            var turn: Int?
            if let turnText {
                guard let found = Int(turnText), found > 0 else { throw CLIError.usage("--turn needs a turn number") }
                turn = found
            }
            do {
                let lines = try ThreadLog.read(at: url).transcript(turn: turn)
                for line in lines { out(line) }
                // On stderr, so a pipe into `jq` still gets nothing but lines; a turn from before every provider kept one has none.
                if lines.isEmpty { err("no transcript is stored for \(turn.map { "turn \($0)" } ?? "this thread")") }
            } catch let error as ThreadLogError {
                throw CLIError.message("\(error); `gzip -t` on its .gz says more")
            }
            return
        }
        if turnText != nil { throw CLIError.usage("--turn goes with --transcript") }

        // `--json`: the stored lines themselves, one event each, nothing added. A transcript line is printed as the
        // `claude` event it would have been.
        if Output.json {
            var threadLog = try ThreadLog.read(at: url)
            var contents = threadLog.contents
            var (lines, position) = threadLog.jsonLines(after: ThreadLog.Position())
            for line in lines { out(line) }
            guard follow else { return }
            let config = try? Config.load(from: ctx.project.configURL)
            let checks = config?.checkCommand != nil
            // Asked when a turn or its check ends, not at the start: the base commit is not known before the worktree is.
            func willVerify(_ event: Event) async -> Bool {
                guard let config, [.turnEnded, .checkRan].contains(event.kind) else { return false }
                return await ctx.service.verifierWillRun(id: id, config: config)
            }
            var turnSucceeded = LogFormatter.latestTurnSucceeded(contents.events)
            var sawStart = contents.openTurn != nil || contents.openCheck != nil || contents.openVerifier != nil
            var seen = contents.events.count
            while true {
                try await Task.sleep(nanoseconds: 300_000_000)
                threadLog = try ThreadLog.read(at: url)
                contents = threadLog.contents
                (lines, position) = threadLog.jsonLines(after: position)
                for line in lines { out(line) }
                for event in contents.events.dropFirst(seen) {
                    if event.kind == .turnStarted { sawStart = true }
                    if event.kind == .turnEnded { turnSucceeded = event.data["result"]?.stringValue == "succeeded" }
                    let verifiers = await willVerify(event)
                    let done = LogFormatter.followEnds(
                        event, sawStart: sawStart, checks: checks, turnSucceeded: turnSucceeded, verifiers: verifiers)
                    if done {
                        return
                    }
                }
                seen = contents.events.count
            }
        }

        func show(_ event: Event) {
            // One line per check: how it ended.
            if event.kind == .checkStarted, !verbose { return }
            // Only the verifier's files are proof; a line without `source` is an old verify step's.
            if event.kind == .proofAdded, event.data["source"]?.stringValue != "verifier" { return }
            // An older log's verify step: the step is gone, so its lines are not described.
            if ["verify.started", "verify.ended"].contains(event.kind.rawValue) { return }
            out(LogFormatter.describe(event))
        }

        var threadLog = try ThreadLog.read(at: url)
        var contents = threadLog.contents
        // Already in the middle of a turn or of its check: follow until that ends.
        let startedWithOpenTurn = contents.openTurn != nil || contents.openCheck != nil || contents.openVerifier != nil
        var (shown, position) = threadLog.entries(after: ThreadLog.Position())
        for entry in shown { show(entry) }
        guard follow else { return }

        // A turn is followed to the end of its check and of its verifier, when they will run.
        let config = try? Config.load(from: ctx.project.configURL)
        let checks = config?.checkCommand != nil
            // Asked when a turn or its check ends, not at the start: the base commit is not known before the worktree is.
            func willVerify(_ event: Event) async -> Bool {
                guard let config, [.turnEnded, .checkRan].contains(event.kind) else { return false }
                return await ctx.service.verifierWillRun(id: id, config: config)
            }
        var turnSucceeded = LogFormatter.latestTurnSucceeded(contents.events)
        var sawStart = startedWithOpenTurn
        while true {
            try await Task.sleep(nanoseconds: 300_000_000)
            threadLog = try ThreadLog.read(at: url)
            contents = threadLog.contents
            (shown, position) = threadLog.entries(after: position)
            for event in shown {
                show(event)
                if event.kind == .turnStarted { sawStart = true }
                if event.kind == .turnEnded { turnSucceeded = event.data["result"]?.stringValue == "succeeded" }
                let verifiers = await willVerify(event)
                let done = LogFormatter.followEnds(
                    event, sawStart: sawStart, checks: checks, turnSucceeded: turnSucceeded, verifiers: verifiers)
                if done {
                    return
                }
            }
        }
    }

    static func status(_ args: [String]) async throws {
        var a = Arguments(args)
        let all = a.flag("--all")
        let fetch = a.flag("--fetch")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        if all {
            if named != nil { throw CLIError.usage("status --all lists every thread; it takes no id") }
            if fetch { throw CLIError.usage("status --all lists threads; --fetch checks one thread's base") }
            statusAll(ctx: ctx)
            return
        }

        // A named thread that does not exist is an error; only "no threads at all" is a friendly line.
        if named != nil { _ = try ctx.threadIDForViewing(named) }
        guard let id = try? ctx.threadIDForViewing(named) else {
            if Output.json { throw CLIError.notFound("no threads yet. Start one: workbench goal new <name>") }
            out("no threads yet. Start one: workbench goal new <name>")
            return
        }
        if Output.json {
            printJSON(await statusJSON(id: id, ctx: ctx, fetch: fetch))
            return
        }
        // Replayed once: the removed-worktree note below reads the same events.
        let events = (try? EventLogReader.read(at: ctx.project.eventsURL(id)))?.events ?? []
        let state = ctx.store.state(from: events, id: id)
        out("thread:    \(id)\(state.isActive ? "" : "  (ended: \(state.decision ?? "?"))")")
        for line in lineageLines(state, ctx: ctx) { out(line) }

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
                if goal.isTimeoutOnly {
                    out("base:      \(goal.base)")
                    out("spend:     \(goal.spendLine)")
                } else {
                    out("base:      \(goal.base)   budget $\(goal.budgetUSD ?? 0)/turn   timeout \(goal.turnTimeoutMin) min")
                }
                if let model = goal.model { out("model:     \(model)") }
                if let pushTo = goal.pushTo { out("push to:   \(pushTo)") }
                if let line = await baseGapLine(goal.base, ctx: ctx, fetch: fetch) { out("           \(line)") }
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
        out(ReviewReport.planLine(for: state))
        for line in state.agentLines() { out(line) }
        out("cost:      \(ReviewReport.costText(state)) (list price; not what a subscription charges)")
        if state.openTurn != nil { out("           the open turn's cost is reported when it ends") }
        for note in state.review.notes { out("note:      turn \(note.turn): " + ReviewReport.oneLine(note.text)) }
        let worktree = ctx.project.worktreesDirectory.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: worktree.path) {
            out("worktree:  \(worktree.path)")
        } else if events.contains(where: { $0.kind == .worktreeRemoved }) {
            out("worktree:  removed after shipping (branch \(WorktreeManager.branch(for: id)) is kept)")
        }
    }

    /// One line per thread on disk, newest first. A view over `.workbench/threads/`, not a thread list to act on.
    static func statusAll(ctx: Context) {
        let states = ctx.store.threadIDs().map { ctx.store.state(of: $0) }
            .sorted { ($0.createdAt ?? "", $0.id) > ($1.createdAt ?? "", $1.id) }
        if Output.json {
            printJSON(statusAllJSON(states))
            return
        }
        if states.isEmpty {
            out("no threads yet. Start one: workbench goal new <name>")
            return
        }
        for state in states {
            // How it ended: the decision once there is one, else where the thread stands.
            var line = state.decision ?? statusString(state.review.status)
            if let result = state.lastResult { line += " (last turn \(result))" }
            let follows = state.lineage.map { "  (follows \($0.parent), round \($0.round))" } ?? ""
            out("\(state.id)  \(line)  \(listCost(state))\(follows)")
        }
    }

    /// Where a review follow-up came from, and the follow-ups a thread has: the tree `ship --review-loop` builds.
    /// A thread's cost in a list: `$0.37`, or `unknown` when a turn reported none (never `$0.00`).
    static func listCost(_ state: ThreadState) -> String {
        state.knownCostUSD.map { String(format: "$%.2f", $0) } ?? "unknown"
    }

    static func lineageLines(_ state: ThreadState, ctx: Context) -> [String] {
        var lines: [String] = []
        if let lineage = state.lineage {
            lines.append("follows:   \(lineage.parent)  (review follow-up \(lineage.round) of \(lineage.root))")
        }
        let kids = children(of: state.id, ctx: ctx)
        if !kids.isEmpty {
            lines.append("follow-ups: \(kids.count) from the review loop")
            for kid in kids {
                let how = kid.decision ?? statusString(kid.review.status)
                lines.append("  round \(kid.lineage?.round ?? 0)  \(kid.id)  \(how)  \(listCost(kid))")
            }
        }
        return lines
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
        let fetch = a.flag("--fetch")
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
            printJSON(await reviewJSON(report, ctx: ctx, fetch: fetch))
            return
        }
        for line in report.render() { out(line) }
        for line in lineageLines(report.state, ctx: ctx) { out(line) }
        if let text = try? String(contentsOf: ctx.project.goalURL(id), encoding: .utf8),
            let goal = try? GoalFile.parse(text).goal, let line = await baseGapLine(goal.base, ctx: ctx, fetch: fetch) {
            out("")
            out("Base       \(line)")
        }
    }

    /// One line when the base branch is behind its origin counterpart or could not be compared; nil when
    /// there is nothing to say. Without `fetch` it uses the origin ref this repository already has and says how
    /// old that is, so a read-only command never waits for the network; with it, fetches that one branch,
    /// bounded, and offline is a note, not an error.
    static func baseGapLine(_ base: String, ctx: Context, fetch: Bool) async -> String? {
        let manager = WorktreeManager(repoRoot: ctx.project.root, git: ctx.git)
        guard let gap = await manager.baseGap(base: base, fetch: fetch) else { return nil }
        var parts: [String] = []
        if gap.behind > 0 {
            var line = "\(base) is \(gap.behind) commit\(gap.behind == 1 ? "" : "s") behind origin/\(base)"
            switch gap.knownFrom {
            case nil: break
            case .lastFetch(let date)?:
                line += " (as of the last fetch, \(ageText(Date().timeIntervalSince(date))); `--fetch` checks now)"
            case .unknown?: line += " (as of the last fetch; `--fetch` checks now)"
            }
            parts.append(line)
        }
        if let note = gap.fetchNote { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(Int(seconds / 60)) min ago"
        case ..<86400: "\(Int(seconds / 3600)) h ago"
        default: "\(Int(seconds / 86400)) d ago"
        }
    }
}
