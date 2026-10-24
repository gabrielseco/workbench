import Foundation
import WorkbenchCore

extension Commands {
    /// What one review of the pull request came to.
    private enum LoopReview {
        case clean(round: Int)
        case findings(round: Int, text: String, last: Bool)
        case stop(Int32)
    }

    /// `ship --review-loop`: Codex reviews the pull request; when it finds something to fix, a follow-up thread on
    /// the same branch gets the findings as its request, runs with its check, and (after you say yes, or with
    /// `--yes`) is pushed; then the new tip is reviewed. Stops on a clean review, the round cap, a failed check,
    /// a turn that was stopped, timed out or went over budget, a reviewer that gave no verdict, or a no. Never merges.
    static func reviewLoop(from start: String, ctx: Context, yes: Bool) async throws -> Int32 {
        let config = try Config.load(from: ctx.project.configURL)
        let maxRounds = config.prReview.maxRounds
        let budget = NSDecimalNumber(decimal: config.defaultBudgetUSD).doubleValue
        out()
        out("review loop: Codex reviews the pull request and, for what it finds, a follow-up thread fixes it")
        out(
            "  at most \(maxRounds) review\(maxRounds == 1 ? "" : "s") of this pull request, so at most \(maxRounds - 1) "
                + "follow-up\(maxRounds == 2 ? "" : "s") of up to $\(String(format: "%.2f", budget)) each; nothing is merged")
        var current = start
        while true {
            switch try await reviewOnce(current, ctx: ctx, config: config) {
            case .stop(let code): return code
            case .clean(let round):
                out("the review is clean after \(round) round\(round == 1 ? "" : "s")")
                return 0
            case .findings(let round, let text, let last):
                out()
                out(text.trimmingCharacters(in: .whitespacesAndNewlines))
                out()
                if last {
                    out("round \(round) found things to fix and max_rounds (\(maxRounds)) is reached, so nothing more is run.")
                    out("the findings above are in the thread's pr-review folder; fix them by hand or raise max_rounds")
                    return FailureKind.findings.code
                }
                switch try await followUp(of: current, findings: text, round: round, ctx: ctx, config: config, yes: yes) {
                case .next(let thread): current = thread
                case .stop(let code): return code
                }
            }
        }
    }

    private enum FollowUp {
        case next(String)
        case stop(Int32)
    }

    /// One review of `id`'s pull request, with Ctrl-C ending it.
    private static func reviewOnce(_ id: String, ctx: Context, config: Config) async throws -> LoopReview {
        out()
        out("asking Codex to review the pull request (read-only; this can take several minutes)...")
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the review") { holder.stop() }
        defer {
            signals.forEach { $0.cancel() }
            restoreDefaultSignals()
        }
        let result: PRReviewResult
        do {
            result = try await ctx.service.prReview(
                id: id, config: config, codexPath: config.executable(for: .codex),
                stopRequested: { holder.isStopRequested }, attach: { holder.attach($0) })
        } catch let error as PRReviewRefusal {
            return try await resume(after: error, id: id, ctx: ctx, config: config)
        }
        for warning in result.warnings { out("note: \(warning)") }
        if holder.isStopRequested { return .stop(fail(.stopped, "the review was stopped.")) }
        let label = "round \(result.round) of \(result.maxRounds)"
        switch result.verdict {
        case .clean?:
            if let findings = result.findings { out(); out(findings.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return .clean(round: result.round)
        case .fix?:
            return .findings(round: result.round, text: result.findings ?? "", last: result.round >= result.maxRounds)
        case nil:
            return .stop(fail(.failed, "no verdict for \(label): \(result.failure ?? "unknown")"))
        }
    }

    /// A review that was refused because the branch was already reviewed, or the cap was reached, still has an answer on
    /// record: use it, so a loop can pick up where an earlier one stopped.
    private static func resume(
        after error: PRReviewRefusal, id: String, ctx: Context, config: Config
    ) async throws -> LoopReview {
        switch error {
        case .alreadyReviewed, .capReached:
            guard let record = ctx.service.latestPRReview(id: id) else { throw CLIError.refused("\(error)") }
            guard record.ok, let verdict = record.verdict else {
                return .stop(fail(.failed, "the last review (round \(record.round)) has no verdict, and \(error)"))
            }
            // The answer on record is only the answer for the commit it looked at.
            guard let tip = await ctx.service.pullRequestBranchTip(id: id) else {
                throw CLIError.message("origin could not be read, so the answer on record cannot be checked against the branch.")
            }
            if tip != record.headSHA {
                throw CLIError.refused(
                    "the branch has moved since round \(record.round) reviewed it, and \(error) "
                        + "Raise max_rounds in [pr_review] to review the new commits.")
            }
            guard let text = ctx.service.prReviewFindings(record) else { throw CLIError.refused("\(error)") }
            out("\(error)")
            if verdict == .clean { return .clean(round: record.round) }
            return .findings(round: record.round, text: text, last: record.round >= config.prReview.maxRounds)
        case .originUnreadable: throw CLIError.message("\(error)")
        default: throw CLIError.refused("\(error)")
        }
    }

    /// Starts the follow-up for a round, runs it, shows what it did, asks, then accepts and ships it.
    private static func followUp(
        of parent: String, findings: String, round: Int, ctx: Context, config: Config, yes: Bool
    ) async throws -> FollowUp {
        let child: String
        do {
            child = try await ctx.service.startFollowUp(parent: parent, findings: findings, reviewRound: round, config: config)
        } catch let error as FollowUpError {
            if case .tooMany = error {
                out("\(error)")
                return .stop(FailureKind.findings.code)
            }
            throw CLIError.refused("\(error)")
        }
        out("round \(round) found things to fix: follow-up thread \(child) started on the same branch")

        let code = try await runTurn(ctx: ctx, id: child, options: RunOptions())
        restoreDefaultSignals()
        if code != 0 { return .stop(code) }
        if config.checkCommand != nil {
            let check = ctx.store.state(of: child).review.check
            if check?.result != "passed" {
                return .stop(
                    fail(
                        .checkFailed,
                        "the check did not pass for \(child) (\(check?.result ?? "it did not run")). Nothing was pushed; "
                            + "`workbench review` shows it and `workbench send-back` is for fixing it."))
            }
        }

        let plan: AcceptPlan
        do { plan = try await ctx.service.acceptPlan(id: child) } catch ThreadServiceError.nothingToAccept {
            out("the follow-up changed nothing, so the findings were not acted on and nothing is pushed.")
            out("\(child) is left as it is: `workbench review` to look, `workbench abandon` to drop it")
            return .stop(FailureKind.findings.code)
        }
        let report = await ReviewLoader(project: ctx.project, git: ctx.git).load(id: child)
        if case .summary(let diff) = report.diff {
            out()
            let files = "\(diff.totalFiles) file\(diff.totalFiles == 1 ? "" : "s")"
            out("the follow-up changes \(files) (+\(diff.additions) -\(diff.deletions)):")
            for file in diff.files.prefix(15) { out("  \(file.path)") }
            if diff.files.count > 15 { out("  ... and \(diff.files.count - 15) more") }
        }
        let interactive = isatty(STDIN_FILENO) == 1
        if !yes && interactive { print("Push this fix to the pull request? [y/N] ", terminator: "") }
        switch Confirmation.ask(yes: yes, interactive: interactive, readLine: { readLine() }) {
        case .proceed: break
        case .declined:
            out("nothing pushed. \(child) is waiting: `workbench review`, then `workbench accept` and `workbench ship`")
            return .stop(0)
        case .refused:
            throw CLIError.refused("not pushing: there is no terminal to ask on. Pass --yes to confirm.")
        }

        do {
            // What was shown is what is committed: edits made while the question waited are refused.
            try await ctx.service.accept(id: child, message: "fix: address review round \(round)", shown: plan)
        } catch let error as ThreadServiceError {
            throw CLIError.refused("\(error)")
        }
        let shipped = try await ship([child, "--yes", "--no-describe"])
        if shipped != 0 { return .stop(shipped) }
        return .next(child)
    }

    /// Ctrl-C between phases must end the command, not be ignored: a phase's handler leaves the signal ignored.
    static func restoreDefaultSignals() {
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
