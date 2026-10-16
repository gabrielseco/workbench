import Foundation
import WorkbenchCore

extension Commands {
    /// `pr-review [id] [--again]`: after `ship`, Codex reviews the thread's pull request, read-only, in a throwaway
    /// checkout of its head. The findings are printed and the round is recorded; `review` shows it. A round that
    /// has no `VERDICT:` line is a failure, never a pass. At most `max_rounds` per pull request, counted from the
    /// thread's log, and `--again` (re-review an unchanged branch) does not lift that.
    static func prReview(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let again = a.flag("--again")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadIDForViewing(named)
        let config = try Config.load(from: ctx.project.configURL)
        out("asking Codex to review the pull request of \(id) (read-only; this can take several minutes)...")
        // Ctrl-C stops Codex instead of leaving it running.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the review") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: PRReviewResult
        do {
            result = try await ctx.service.prReview(
                id: id, config: config, again: again, stopRequested: { holder.isStopRequested }, attach: { holder.attach($0) })
        } catch let error as PRReviewRefusal {
            switch error {
            case .originUnreadable: throw CLIError.message("\(error)")
            default: throw CLIError.refused("\(error)")
            }
        }
        for warning in result.warnings { out("note: \(warning)") }
        let label = "round \(result.round) of \(result.maxRounds), pull request #\(result.pr)"
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
