import Foundation
import WorkbenchCore

extension Commands {
    /// `pr-review [id] [--again]`: after `ship`, Codex reviews the thread's pull request, read-only, in a throwaway
    /// checkout of its head. The findings are printed and the round is recorded; `review` shows it. A round that
    /// has no `VERDICT:` line is a failure, never a pass. At most `max_rounds` per pull request, counted from the
    /// thread's log, and `--again` (re-review an unchanged branch) does not lift that.
    static func prReview(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        if let value = try a.value("--pr") {
            let spec = try a.value("--spec")
            let again = a.flag("--again")
            try a.requireEmpty()
            guard let number = Int(value), number > 0 else {
                throw CLIError.usage("--pr needs a pull request number, not '\(value)'")
            }
            return try await reviewPullRequest(number: number, specPath: spec, again: again)
        }
        return try await reviewStage(name: ReviewConfig.prReviewStage, args)
    }

    /// `pr-review --pr <n> [--spec <file>] [--again]`: the same review for a pull request no thread made. The goal is
    /// the pull request's own text, or `--spec`. Nothing is recorded in a thread's log and no round is counted; the
    /// findings are kept under `.workbench/reviews/`.
    private static func reviewPullRequest(number: Int, specPath: String?, again: Bool) async throws -> Int32 {
        let ctx = try await Context.load()
        let config = try Config.load(from: ctx.project.configURL)
        guard let gh = try? GitRunner.discover(tool: "gh", timeout: 60) else {
            throw CLIError.refused("`gh` is not on PATH; it reads the pull request's branch and text")
        }
        let spec = try specPath.map { try readSpec($0) }
        out(ReviewProgress.pullRequest(number, config: config))
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the review") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: PRReviewResult
        do {
            result = try await ctx.service.reviewPullRequest(
                number: number, spec: spec, config: config, gh: gh, again: again,
                codexPath: config.executable(for: .codex),
                stopRequested: { holder.isStopRequested }, attach: { holder.attach($0) })
        } catch let error as PRReviewRefusal {
            switch error {
            case .originUnreadable, .pullRequestUnreadable: throw CLIError.message("\(error)")
            default: throw CLIError.refused("\(error)")
            }
        }
        for warning in result.warnings { out("note: \(warning)") }
        guard let verdict = result.verdict else {
            if let findings = result.findings { out(""); out(findings) }
            out("no verdict for pull request #\(number): \(result.failure ?? "unknown")")
            if let path = result.findingsPath { out("what Codex wrote: \(path)") }
            return FailureKind.failed.code
        }
        out("")
        if let findings = result.findings { out(findings.trimmingCharacters(in: .whitespacesAndNewlines)) }
        out("")
        if let path = result.findingsPath { out("kept: \(path)") }
        switch verdict {
        case .clean:
            out("pull request #\(number): clean")
            return 0
        case .fix:
            out("pull request #\(number): findings to fix")
            return FailureKind.findings.code
        }
    }

    /// The file `--spec` names, read whole: a regular file of at most 64 KiB, read as text.
    private static func readSpec(_ path: String) throws -> (text: String, path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let limit = 64 << 10
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? Int, size <= limit,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw CLIError.refused("--spec \(path) is not a readable text file of at most 64 KiB") }
        return (text, url.path)
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
        out(ReviewProgress.stage(name, thread: id, config: config))
        // Ctrl-C stops Codex instead of leaving it running.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the review") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: PRReviewResult
        do {
            result = try await ctx.service.reviewStage(
                named: name, id: id, config: config, again: again, codexPath: config.executable(for: .codex),
                stopRequested: { holder.isStopRequested },
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
            (isPRReview ? "" : "\(name) ") + "round \(result.round) of \(result.maxRounds), "
            + (result.pr == PRReview.noPullRequest ? "the thread's branch" : "pull request #\(result.pr)")
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
