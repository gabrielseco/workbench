import Foundation

extension ThreadService {
    /// Explains pull request `number` in Markdown, with the plumbing of `reviewPullRequest`: the pull request read with
    /// `gh`, its head fetched from origin and checked out in a throwaway worktree, the base pinned, the diff in a file,
    /// and the review agent run read-only. Nothing is recorded in a thread's log and nothing is posted.
    ///
    /// The explanation is kept at `.workbench/explains/pr-<n>-<head7>.md`, and also written to `out` when one is given.
    /// A head that has not moved reuses that file without running the agent, unless `again`. An empty or missing answer
    /// is a failure and writes no file.
    public func explainPullRequest(
        number: Int, spec: (text: String, path: String)?, config: Config, gh: GitRunner, again: Bool = false,
        out: URL? = nil, codexPath: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = PRReview.timeout,
        capacityBackoff: @escaping @Sendable (Int) -> TimeInterval = { TimeInterval($0 * 20) },
        stopRequested: @escaping @Sendable () -> Bool = { false },
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> PRExplainResult {
        // As for a review: `gh` reads the repository of the directory it runs in, never a `GH_REPO` from the shell.
        let gh = GitRunner(
            executable: gh.executable, environment: gh.environment.filter { $0.key != "GH_REPO" }, timeout: gh.timeout)
        let reviews = project.workbenchDirectory.appendingPathComponent("reviews", isDirectory: true)
        let explains = project.workbenchDirectory.appendingPathComponent(PRExplain.folderName, isDirectory: true)
        // The reviews' lock: an explanation fetches into the same `FETCH_HEAD` as a review by number.
        guard let lock = FolderLock(folder: reviews) else { throw PRReviewRefusal.busy }
        defer { lock.release() }
        await recoverByNumberLeftovers()

        let info = try await pullRequestInfo(number, gh: gh)
        let tip = try await originBranchTip(info.branch)
        let kept = explains.appendingPathComponent(PRExplain.fileName(pr: number, head: tip))
        func result(
            file: URL?, reused: Bool, failure: String? = nil, transcript: String? = nil, warnings: [String] = []
        ) -> PRExplainResult {
            PRExplainResult(
                pr: number, headSHA: tip, file: file, reused: reused, failure: failure, transcriptPath: transcript,
                warnings: warnings)
        }

        if !again, let text = try? String(contentsOf: kept, encoding: .utf8), PRExplain.body(text) != nil {
            if let out {
                if let why = Self.write(text, to: out) { return result(file: nil, reused: true, failure: why) }
                return result(file: out, reused: true)
            }
            return result(file: kept, reused: true)
        }

        let folder = explains.appendingPathComponent("pr-\(number)-\(tip.prefix(7))", isDirectory: true)
        let paths = PRReviewPaths(folder: folder, round: 1)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = PRReviewSettings(
            codexPath: codexPath, environment: environment, timeout: timeout,
            capacityBackoff: capacityBackoff, stopRequested: stopRequested)
        var round = PRReviewRound(
            id: "pr-\(number)", task: .explain, stage: .prReview(config), pr: number, branch: info.branch,
            base: info.base, recordedBase: nil, goal: spec?.text ?? "# \(info.title)\n\n\(info.body)",
            goalRest: spec?.path ?? "pull request #\(number) on GitHub", tip: tip, paths: paths, config: config,
            settings: settings)
        let outcome = await runRound(&round, attach: attach)
        await removeTree(paths)

        let transcript = FileManager.default.fileExists(atPath: paths.transcript.path)
            ? ".workbench/\(PRExplain.folderName)/\(folder.lastPathComponent)/\(paths.transcript.lastPathComponent)" : nil
        if let failure = outcome.failure {
            let reason = Self.withoutCredentials(PRBodyBuilder.scrub(failure))
            return result(file: nil, reused: false, failure: reason, transcript: transcript, warnings: outcome.warnings)
        }
        guard let body = outcome.findings.flatMap(PRExplain.body) else {
            return result(
                file: nil, reused: false, failure: "\(round.agent.provider) wrote an empty explanation; no file was written",
                transcript: transcript, warnings: outcome.warnings)
        }
        // The reported file first: when it cannot be written, nothing is kept either, so the next run does not reuse an
        // explanation whose run failed.
        var warnings = outcome.warnings
        if let out {
            if let why = Self.write(body, to: out) {
                return result(file: nil, reused: false, failure: why, transcript: transcript, warnings: warnings)
            }
            if let why = Self.write(body, to: kept) { warnings.append("not kept for reuse: \(why)") }
            return result(file: out, reused: false, transcript: transcript, warnings: warnings)
        }
        if let why = Self.write(body, to: kept) {
            return result(file: nil, reused: false, failure: why, transcript: transcript, warnings: warnings)
        }
        return result(file: kept, reused: false, transcript: transcript, warnings: warnings)
    }

    /// Writes the whole file or nothing (a reader never sees half an explanation); the reason when it could not.
    private static func write(_ text: String, to url: URL) -> String? {
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch {
            return "the explanation could not be written to \(url.path): \(error.localizedDescription)"
        }
        return nil
    }
}
