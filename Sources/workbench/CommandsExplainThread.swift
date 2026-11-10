import Foundation
import WorkbenchCore

extension Commands {
    /// `explain-thread --pr <n> --thread <id>`: the review agent explains one review thread of a pull request, read-only,
    /// in a throwaway checkout of its head (the plumbing of `explain-pr`). The last stdout line is one JSON object with
    /// `reasoning` and `proposed_fix`. The contract is docs/plan/explain-thread.md.
    static func explainThread(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let value = try a.value("--pr")
        let threadID = try a.value("--thread")
        try a.requireEmpty()
        guard let value else { throw CLIError.usage("explain-thread needs --pr <n>, the pull request the thread is on") }
        guard let number = Int(value), number > 0 else {
            throw CLIError.usage("--pr needs a pull request number, not '\(value)'")
        }
        guard let threadID else {
            throw CLIError.usage("explain-thread needs --thread <id>, the GraphQL id of the review thread (PRRT_…)")
        }
        guard ThreadExplain.isThreadID(threadID) else {
            throw CLIError.usage("--thread needs a GraphQL node id such as PRRT_kwDOAbc123, not '\(threadID)'")
        }

        let ctx = try await Context.load()
        let config = try Config.load(from: ctx.project.configURL)
        let gh = try pullRequestGH()
        out(ReviewProgress.explainThread(number, config: config))
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the explanation") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: ThreadExplainResult
        do {
            result = try await ctx.service.explainReviewThread(
                number: number, thread: threadID, config: config, gh: gh, codexPath: config.executable(for: .codex),
                stopRequested: { holder.isStopRequested }, attach: { holder.attach($0) })
        } catch let error as PRReviewRefusal {
            switch error {
            case .originUnreadable, .pullRequestUnreadable: throw CLIError.message("\(error)")
            default: throw CLIError.refused("\(error)")
            }
        } catch let error as ThreadExplainRefusal {
            if case .unreadable = error { throw CLIError.message("\(error)") }
            throw CLIError.refused("\(error)")
        }
        for warning in result.warnings { out("note: \(warning)") }
        guard let reasoning = result.reasoning, let fix = result.proposedFix else {
            let kept = result.transcriptPath.map { " (what it wrote: \($0))" } ?? ""
            return fail(
                .failed, "no explanation of thread \(threadID) on pull request #\(number): \(result.failure ?? "unknown")\(kept)")
        }
        // The contract: the last line on stdout is this one object, on one line.
        printJSON([
            "pr": .int(number), "thread": .string(threadID), "head_sha": .string(result.headSHA),
            "reasoning": .string(reasoning), "proposed_fix": .string(fix),
        ])
        return 0
    }
}
