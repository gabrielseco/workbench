import Foundation
import WorkbenchCore

extension Commands {
    /// `ship [id] [--yes] [--no-describe] [--refresh-description]`: push the accepted thread's branch and open its pull request. The
    /// title and description are written by a read-only Claude turn from the goal, the diff and the check;
    /// `--no-describe` (or a failed turn) uses the goal-based body. Asks first, because it publishes, and
    /// shows what it will publish; running it again after any failure resumes where it stopped.
    static func ship(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let yes = a.flag("--yes", "-y")
        let watch = a.flag("--watch", "-w")
        let keepWorktree = a.flag("--keep-worktree")
        let noDescribe = a.flag("--no-describe")
        let noScreenshots = a.flag("--no-screenshots")
        let screenshotsOnly = a.flag("--screenshots")
        let refreshText = a.flag("--refresh-description")
        let wantsLoop = a.flag("--review-loop")
        let minutes = try a.value("--timeout")
        let seconds = try a.value("--interval")
        let named = a.positional()
        try a.requireEmpty()
        let limits = try watchLimits(watch: watch, minutes: minutes, seconds: seconds)
        try checkLoopFlags(wantsLoop: wantsLoop, watch: watch, screenshotsOnly: screenshotsOnly, yes: yes)
        let ctx = try await Context.load()
        if screenshotsOnly { return try await retryScreenshots(named, ctx: ctx) }
        let gh = try? GitRunner.discover(tool: "gh")

        let id: String
        do {
            id = try shippableThread(named, ctx: ctx)
        } catch let error as ShipError {
            // With --watch a thread that is already shipped is simply followed.
            // An id that was named is never swapped for another thread.
            if wantsLoop, named == nil, let shipped = latestShipped(ctx: ctx) {
                out("\(shipped) is already shipped; starting at the review")
                return try await reviewLoop(from: shipped, ctx: ctx, yes: yes)
            }
            guard watch, named == nil, let shipped = latestShipped(ctx: ctx) else { return refuse(error) }
            return await follow(id: shipped, ctx: ctx, gh: gh, limits: limits)
        }
        if watch, isShipped(id, ctx: ctx) { return await follow(id: id, ctx: ctx, gh: gh, limits: limits) }
        if named == nil { out("shipping \(id)") }

        let plan: ShipPlan
        do { plan = try await ctx.service.shipPreflight(id: id, gh: gh) } catch let error as ShipError {
            // A shipped thread whose worktree is still there gets it removed now, under the same rules.
            if case .alreadyShipped = error, !keepWorktree { await cleanUp(id: id, ctx: ctx, gh: gh) }
            if wantsLoop, case .alreadyShipped = error {
                out("\(id) is already shipped; starting at the review")
                return try await reviewLoop(from: id, ctx: ctx, yes: yes)
            }
            return refuse(error)
        }
        out("thread:  \(plan.id)")
        out("branch:  \(plan.branch)  (\(plan.head.prefix(12)))")
        if plan.updatesExistingBranch {
            out("updates: \(plan.remoteBranch) on origin")
        } else {
            out("base:    \(plan.base)")
        }
        out("origin:  \(plan.origin)")
        switch plan.remote {
        case .absent: out("push:    new branch on origin")
        case .upToDate: out("push:    nothing, origin already has this commit")
        case .behind(let sha): out("push:    fast-forward from \(sha.prefix(12))")
        }
        if plan.updatesExistingBranch {
            out("then:    record the open pull request for \(plan.remoteBranch); its title and description stay as they are")
        } else {
            out("then:    open a pull request against \(plan.base)")
        }

        var description: PRDescription?
        if !noDescribe && !plan.updatesExistingBranch {
            if let config = try? Config.load(from: ctx.project.configURL) {
                out("describing the change...")
                let described = try await ctx.service.describePR(plan: plan, config: config)
                description = described.description
                if let why = described.fallback {
                    out("could not describe the change (\(why)); using the goal-based description")
                }
            } else {
                out("no readable .workbench/config.toml; using the goal-based description")
            }
        }
        var refresh: PRRefreshProposal?
        if plan.updatesExistingBranch && !noDescribe { refresh = try await proposeRefresh(plan: plan, ctx: ctx) }
        if !plan.updatesExistingBranch {
            do {
                let preview = try await ctx.service.prBody(
                    plan: plan, description: description, environment: gh?.environment ?? [:])
                out("title:   \(preview.title)")
                out("")
                out(preview.body.trimmingCharacters(in: .newlines))
                out("")
            } catch let error as ShipError {
                return refuse(error)
            }
        }

        let interactive = isatty(STDIN_FILENO) == 1
        if !yes && interactive { print("Publish this? [y/N] ", terminator: "") }
        switch Confirmation.ask(yes: yes, interactive: interactive, readLine: { readLine() }) {
        case .proceed: break
        case .declined:
            out("nothing changed")
            // With --watch, exit 0 means every check passed; no PR was made, so there is nothing to claim.
            return watch ? 1 : 0
        case .refused:
            throw CLIError.refused("not shipping: there is no terminal to ask on. Pass --yes to confirm.")
        }

        let applyRefresh = refresh != nil && askRefresh(yes: yes, flag: refreshText, interactive: interactive)
        if refresh != nil && !applyRefresh {
            out("the pull request text is left as is\(yes ? "; pass --refresh-description to update it" : "")")
        }

        do {
            let pushed = try await ctx.service.shipPush(id: id, gh: gh, shown: plan)
            let pushedName = plan.updatesExistingBranch ? plan.remoteBranch : plan.branch
            pushed.ahead.map { out($0.note) }
            out(pushed.outcome == .pushed ? "pushed \(pushedName)" : "origin already has \(pushedName)")
            let pr = try await ctx.service.shipOpenPR(id: id, gh: gh, shown: plan, description: description)
            out(pr.outcome == .created ? "opened the pull request" : "the pull request already existed; recorded it")
            var refreshFailure: ShipError?
            if applyRefresh, let refresh {
                do {
                    try await ctx.service.applyPRRefresh(id: id, plan: plan, proposal: refresh, gh: gh)
                    out("updated the pull request title and description")
                } catch let error as ShipError { refreshFailure = error }
            }
            var attached = true
            if !noScreenshots {
                attached = await attachScreenshots(id: id, worktree: plan.worktree, number: pr.number, ctx: ctx)
            }
            // Kept when the screenshots did not go up, so `ship --screenshots` can try again.
            if !keepWorktree, attached { await cleanUp(id: id, ctx: ctx, gh: gh) }
            out(pr.url)
            if let refreshFailure { return refuse(refreshFailure) }
            if wantsLoop { return try await reviewLoop(from: id, ctx: ctx, yes: yes) }
            return watch ? await follow(id: id, ctx: ctx, gh: gh, limits: limits) : 0
        } catch let error as ShipError {
            return refuse(error)
        }
    }

    /// `--review-loop` asks before every push, so it needs someone to ask (or `--yes`) before anything is spent.
    private static func checkLoopFlags(wantsLoop: Bool, watch: Bool, screenshotsOnly: Bool, yes: Bool) throws {
        guard wantsLoop else { return }
        if watch || screenshotsOnly { throw CLIError.usage("--review-loop cannot be combined with --watch or --screenshots") }
        if !yes && isatty(STDIN_FILENO) != 1 {
            throw CLIError.refused(
                "not starting the review loop: there is no terminal to ask on. Pass --yes to confirm each push.")
        }
    }

    /// Puts the verify step's screenshots in the pull request through `pr-shots`. A note on failure: the PR is open.
    /// Returns false when they were not attached, so the worktree is kept for a retry.
    @discardableResult
    private static func attachScreenshots(id: String, worktree: URL, number: Int, ctx: Context) async -> Bool {
        let tool = try? GitRunner.discover(tool: "pr-shots", timeout: 180)
        switch await ctx.service.shipScreenshots(id: id, worktree: worktree, number: number, tool: tool) {
        case .none: return true
        case .attached(let count):
            out("put \(count) screenshot\(count == 1 ? "" : "s") in the pull request")
            return true
        case .skipped(let why):
            out("note: \(why)")
            out("kept the worktree; `workbench ship --screenshots` tries again")
            return false
        }
    }

    /// `ship --screenshots`: for a thread that is already shipped, try putting its screenshots in the PR again.
    private static func retryScreenshots(_ named: String?, ctx: Context) async throws -> Int32 {
        let id = try ctx.threadIDForViewing(named)
        guard let opened = prOpenedEvent(id, ctx: ctx), let number = opened.data["number"]?.intValue else {
            return refuse(.notAccepted("this thread has no pull request yet; run `workbench ship`"))
        }
        let worktree = WorktreeManager(repoRoot: ctx.project.root, git: ctx.git).path(for: id)
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            out("the worktree is gone, so `pr-shots` has no branch to name the screenshots by")
            return 1
        }
        let attached = await attachScreenshots(id: id, worktree: worktree, number: number, ctx: ctx)
        return attached ? 0 : 1
    }

    /// Removes the shipped thread's worktree when nothing could be lost, and says what happened. A worktree
    /// that stays is a note: the thread is shipped either way, and the next `ship` tries again.
    private static func cleanUp(id: String, ctx: Context, gh: GitRunner?) async {
        switch await ctx.service.cleanShipped(id: id, gh: gh) {
        case .removed(let path): out("removed the worktree \(path); \(WorktreeManager.branch(for: id)) is kept")
        case .kept(let why): out("kept the worktree: \(why)")
        case .alreadyGone, .notShipped: break
        }
    }

    private struct WatchLimits {
        var timeout: TimeInterval
        var interval: TimeInterval
    }

    private static func watchLimits(watch: Bool, minutes: String?, seconds: String?) throws -> WatchLimits {
        if !watch, minutes != nil || seconds != nil { throw CLIError.usage("--timeout and --interval need --watch") }
        func number(_ text: String?, _ name: String, _ range: ClosedRange<Int>, default value: Int) throws -> Int {
            guard let text else { return value }
            guard let n = Int(text), range.contains(n) else {
                throw CLIError.usage("\(name) needs a whole number from \(range.lowerBound) to \(range.upperBound)")
            }
            return n
        }
        return WatchLimits(
            timeout: TimeInterval(try number(minutes, "--timeout (minutes)", 1...240, default: 30) * 60),
            interval: TimeInterval(try number(seconds, "--interval (seconds)", 1...300, default: 15)))
    }

    private static func prOpenedEvent(_ id: String, ctx: Context) -> Event? {
        let events = (try? EventLogReader.read(at: ctx.project.eventsURL(id)))?.events ?? []
        return events.last { $0.kind == .prOpened }
    }

    private static func isShipped(_ id: String, ctx: Context) -> Bool { prOpenedEvent(id, ctx: ctx) != nil }

    private static func latestShipped(ctx: Context) -> String? {
        ctx.store.threadIDs().filter { isShipped($0, ctx: ctx) }
            .max { (ctx.store.state(of: $0).createdAt ?? "") < (ctx.store.state(of: $1).createdAt ?? "") }
    }

    /// Prints each change of the checks once, then the final list, and returns the exit code for it.
    private static func follow(id: String, ctx: Context, gh: GitRunner?, limits: WatchLimits) async -> Int32 {
        if let event = prOpenedEvent(id, ctx: ctx), let url = event.data["url"]?.stringValue {
            out("watching \(url)")
        }
        func line(_ check: PRCheck) -> String {
            let name = check.name.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : String($0) }.joined()
            return "  \(check.bucket.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name)"
        }
        do {
            let result = try await ctx.service.watchPR(
                id: id, gh: gh, interval: limits.interval, timeout: limits.timeout
            ) { summary in
                let count = { (o: PRCheck.Outcome) in summary.checks.filter { $0.outcome == o }.count }
                out("checks: \(count(.passed)) passed, \(count(.pending)) pending, \(count(.failed)) failed")
            }
            switch result {
            case .passed(let checks):
                for check in checks { out(line(check)) }
                out("all checks passed")
                return 0
            case .failed(let checks):
                for check in checks { out(line(check)) }
                return fail(.checkFailed, "a check failed. `workbench send-back` is for fixing it; nothing was changed.")
            case .timedOut(let checks):
                for check in checks { out(line(check)) }
                return fail(
                    .noResult, "checks were still running when the time limit passed. Run `workbench ship --watch` again.")
            case .noChecks:
                return fail(.noResult, "no checks were reported for the pull request.")
            }
        } catch let error as ShipError {
            return refuse(error)
        } catch {
            return fail(.failed, "\(error)")
        }
    }

    /// The thread named, or else the most recent one that is accepted and not yet shipped.
    private static func shippableThread(_ named: String?, ctx: Context) throws -> String {
        if let named {
            // Only a name the store lists is used to build a path.
            guard ctx.store.threadIDs().contains(named) else {
                throw ShipError.notAccepted("there is no thread '\(named)'")
            }
            return named
        }
        let candidates = ctx.store.threadIDs().compactMap { id -> ThreadState? in
            let events = (try? EventLogReader.read(at: ctx.project.eventsURL(id)))?.events ?? []
            let state = ThreadState.derive(from: events, id: id)
            return state.decision == "accepted" && !events.contains { $0.kind == .prOpened } ? state : nil
        }
        guard let latest = candidates.max(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") }) else {
            throw ShipError.notAccepted("there is no accepted thread waiting to be shipped; `workbench accept` one first")
        }
        return latest.id
    }

    /// Prints why and returns the exit code for it. An already shipped thread also prints its URL, last.
    private static func refuse(_ error: ShipError) -> Int32 {
        let code = fail(error.failureKind, "\(error)")
        if case .alreadyShipped(let url) = error { out(url) }
        return code
    }
}
