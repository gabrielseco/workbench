import Foundation
import WorkbenchCore

extension Commands {
    /// `explain-pr --pr <n> [--out <file>] [--spec <file>] [--again]`: the review agent explains a pull request in
    /// Markdown, read-only, in a throwaway checkout of its head (the plumbing of `pr-review --pr`). The last stdout line
    /// is the absolute path of the file, which holds the body only. The contract is docs/plan/explain-pr.md.
    static func explainPR(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let value = try a.value("--pr")
        let specPath = try a.value("--spec")
        let outPath = try a.value("--out")
        let again = a.flag("--again")
        try a.requireEmpty()
        guard let value else { throw CLIError.usage("explain-pr needs --pr <n>, the pull request to explain") }
        guard let number = Int(value), number > 0 else {
            throw CLIError.usage("--pr needs a pull request number, not '\(value)'")
        }

        let ctx = try await Context.load()
        let config = try Config.load(from: ctx.project.configURL)
        let gh = try pullRequestGH()
        let spec = try specPath.map { try readSpec($0) }
        let outURL = try outPath.map { try outFile($0) }
        out(ReviewProgress.explain(number, config: config))
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the explanation") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: PRExplainResult
        do {
            result = try await ctx.service.explainPullRequest(
                number: number, spec: spec, config: config, gh: gh, again: again, out: outURL,
                codexPath: config.executable(for: .codex),
                stopRequested: { holder.isStopRequested }, attach: { holder.attach($0) })
        } catch let error as PRReviewRefusal {
            switch error {
            case .originUnreadable, .pullRequestUnreadable: throw CLIError.message("\(error)")
            default: throw CLIError.refused("\(error)")
            }
        }
        for warning in result.warnings { out("note: \(warning)") }
        guard let file = result.file else {
            let kept = result.transcriptPath.map { " (what it wrote: \($0))" } ?? ""
            return fail(.failed, "no explanation of pull request #\(number): \(result.failure ?? "unknown")\(kept)")
        }
        if result.reused {
            out("pull request #\(number) at \(result.headSHA.prefix(7)) was explained before; --again asks once more")
        }
        // The contract: the last line on stdout is the file's absolute path, alone.
        out(file.standardizedFileURL.path)
        return 0
    }

    /// Where `--out` writes: an absolute path, in a folder that exists, and not a folder itself.
    private static func outFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            throw CLIError.refused("--out \(path) is a folder; name the file to write")
        }
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw CLIError.refused("--out \(path): the folder \(parent.path) does not exist")
        }
        return url
    }
}
