import Foundation
import WorkbenchCore

extension Commands {
    /// `compact (<id> | --all) [--dry-run]`: moves the `claude` lines of logs written before transcript files out of
    /// `events.jsonl`, into the turn's transcript file (see `TranscriptCompactor`). Temporary: it exists for the logs
    /// that are there today. A thread that has not ended is refused; with `--all` it is skipped and said.
    static func compact(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let all = a.flag("--all")
        let dryRun = a.flag("--dry-run")
        let named = a.positional()
        try a.requireEmpty()
        if all == (named != nil) { throw CLIError.usage("compact takes a thread id or --all, not both and not neither") }
        let ctx = try await Context.load()
        let compactor = TranscriptCompactor(project: ctx.project)

        if let named {
            _ = try ctx.threadID(named)
            do {
                switch try await compactor.compact(id: named, dryRun: dryRun) {
                case .compacted(let report): out(describe(report))
                case .nothingToDo: out("\(named): nothing to move; its log holds no stream lines")
                }
            } catch let failure as TranscriptCompactor.Failure {
                switch failure {
                case .active, .running: throw CLIError.refused("\(named): \(failure)")
                default: throw CLIError.message("\(named): \(failure)")
                }
            }
            return 0
        }

        var total = (before: 0, after: 0, disk: 0)
        var done = 0
        var failures: [String] = []
        for id in ctx.store.threadIDs() {
            do {
                switch try await compactor.compact(id: id, dryRun: dryRun) {
                case .compacted(let report):
                    out(describe(report))
                    total.before += report.logBytesBefore
                    total.after += report.logBytesAfter
                    total.disk += report.transcriptDiskBytes
                    done += 1
                case .nothingToDo:
                    break
                }
            } catch TranscriptCompactor.Failure.active {
                out("\(id): skipped, it has not ended")
            } catch let failure as TranscriptCompactor.Failure {
                if case .running = failure { out("\(id): skipped, \(failure)"); continue }
                out("\(id): FAILED, \(failure)")
                failures.append(id)
            }
        }
        if done == 0, failures.isEmpty { out("nothing to move") }
        if done > 0 {
            let verb = dryRun ? "would be" : "were"
            out(
                "\(done) thread(s) \(verb) compacted: logs \(bytes(total.before)) -> \(bytes(total.after)), "
                    + "transcripts \(bytes(total.disk)) gzipped" + (dryRun ? "; nothing was changed (--dry-run)" : ""))
        }
        guard failures.isEmpty else {
            let names = failures.joined(separator: ", ")
            return fail(.failed, "\(failures.count) thread(s) could not be compacted and were left as they were: \(names)")
        }
        return 0
    }

    private static func describe(_ report: TranscriptCompactor.Report) -> String {
        let moved = report.applied ? "moved" : "would move"
        return "\(report.thread): \(report.lines) stream line(s) of \(report.turns.count) turn(s) \(moved); "
            + "log \(bytes(report.logBytesBefore)) -> \(bytes(report.logBytesAfter)), "
            + "transcript \(bytes(report.transcriptDiskBytes)) gzipped"
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
