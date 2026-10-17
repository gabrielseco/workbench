import Foundation
import WorkbenchCore

extension Commands {
    /// `pr-review [id] [--again]`: after `ship`, Codex reviews the thread's pull request, read-only, in a throwaway
    /// checkout of its head. The findings are printed and the round is recorded; `review` shows it. A round that
    /// has no `VERDICT:` line is a failure, never a pass. At most `max_rounds` per pull request, counted from the
    /// thread's log, and `--again` (re-review an unchanged branch) does not lift that.
    static func prReview(_ args: [String]) async throws -> Int32 {
        try await reviewStage(name: ReviewConfig.prReviewStage, args)
    }

    /// `review-stage <name> [id] [--again]`: one round of the stage `<name>` of `review.stages`, as `pr-review` is for
    /// its own name. A stage whose `applies_to` matches no changed path is recorded as skipped and exits 0.
    static func reviewStage(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let again = a.flag("--again")
        guard let name = a.positional() else { throw CLIError.usage("review-stage needs the name of a stage") }
        let named = a.positional()
        try a.requireEmpty()
        return try await reviewStage(name: name, again: again, named: named)
    }

    private static func reviewStage(name: String, _ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let again = a.flag("--again")
        let named = a.positional()
        try a.requireEmpty()
        return try await reviewStage(name: name, again: again, named: named)
    }

    private static func reviewStage(name: String, again: Bool, named: String?) async throws -> Int32 {
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        let config = try Config.load(from: ctx.project.configURL)
        guard ReviewStage.named(name, config: config) != nil else {
            throw CLIError.refused("\(PRReviewRefusal.unknownStage(name, listed: config.review.stages))")
        }
        let isPRReview = name == ReviewConfig.prReviewStage
        out(
            isPRReview
                ? "asking Codex to review the pull request of \(id) (read-only; this can take several minutes)..."
                : "asking Codex to review the pull request of \(id) as the \(name) stage (read-only; this can take "
                    + "several minutes)...")
        // Ctrl-C stops Codex instead of leaving it running.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the review") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: PRReviewResult
        do {
            result = try await ctx.service.reviewStage(
                named: name, id: id, config: config, again: again, stopRequested: { holder.isStopRequested },
                attach: { holder.attach($0) })
        } catch let error as PRReviewRefusal {
            switch error {
            case .originUnreadable: throw CLIError.message("\(error)")
            default: throw CLIError.refused("\(error)")
            }
        }
        for warning in result.warnings { out("note: \(warning)") }
        if result.skipped != nil {
            out("\(name): skipped, the diff touches no matching path")
            return 0
        }
        let label =
            (isPRReview ? "" : "\(name) ") + "round \(result.round) of \(result.maxRounds), pull request #\(result.pr)"
        guard let verdict = result.verdict else {
            if let findings = result.findings { out(""); out(findings) }
            out("no verdict for \(label): \(result.failure ?? "unknown")")
            if let path = result.findingsPath { out("what Codex wrote: \(path) (in the thread's folder)") }
            return FailureKind.failed.code
        }
        out("")
        if let findings = result.findings { out(findings.trimmingCharacters(in: .whitespacesAndNewlines)) }
        out("")
        switch verdict {
        case .clean:
            out("\(label): clean")
            return 0
        case .fix:
            let left = result.maxRounds - result.round
            out("\(label): findings to fix (\(left) review\(left == 1 ? "" : "s") left). `workbench review` shows them.")
            return FailureKind.findings.code
        }
    }
}
