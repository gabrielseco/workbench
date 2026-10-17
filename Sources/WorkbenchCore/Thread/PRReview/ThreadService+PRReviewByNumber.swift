import Foundation

extension ThreadService {
    /// What `gh pr view` says about a pull request, once it is known to be one this review can read.
    struct PullRequestInfo: Equatable {
        var branch: String
        var base: String
        var title: String
        var body: String
    }

    /// Reviews pull request `number` as the `pr-review` stage does, for a pull request no thread made (one written
    /// by hand). The brief's goal is the pull request's own title and description, or `spec` when the person names a
    /// file. There is no thread, so nothing is written to an event log and no round is counted: the findings and
    /// the transcript are kept under `.workbench/reviews/pr-<number>-<sha>/`, and a branch that has not moved is
    /// not reviewed again without `again`. Everything else is the thread's round: the checkout of the branch as
    /// origin has it, the base pinned, the diff in a file, read-only Codex, and a verdict line or a failure.
    public func reviewPullRequest(
        number: Int, spec: (text: String, path: String)?, config: Config, gh: GitRunner, again: Bool = false,
        codexPath: String = "codex", environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = PRReview.timeout,
        capacityBackoff: @escaping @Sendable (Int) -> TimeInterval = { TimeInterval($0 * 20) },
        stopRequested: @escaping @Sendable () -> Bool = { false },
        attach: @Sendable (ProcessRun) -> Void = { _ in }
    ) async throws -> PRReviewResult {
        let info = try await pullRequestInfo(number, gh: gh)
        let tip = try await originBranchTip(info.branch)
        let folder = project.workbenchDirectory
            .appendingPathComponent("reviews/pr-\(number)-\(tip.prefix(7))", isDirectory: true)
        let paths = PRReviewPaths(folder: folder, round: 1)
        if !again, FileManager.default.fileExists(atPath: paths.answer.path) {
            throw PRReviewRefusal.alreadyReviewed(round: 1)
        }
        // A review that was killed left its checkout behind; end it before making this one.
        await removeTree(paths)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let settings = PRReviewSettings(
            codexPath: codexPath, environment: environment, timeout: timeout,
            capacityBackoff: capacityBackoff, stopRequested: stopRequested)
        var round = PRReviewRound(
            id: "pr-\(number)", stage: .prReview(config), pr: number, branch: info.branch, base: info.base,
            recordedBase: nil, goal: spec?.text ?? "# \(info.title)\n\n\(info.body)",
            goalRest: spec?.path ?? "pull request #\(number) on GitHub", tip: tip, paths: paths, config: config,
            settings: settings)
        let outcome = await runRound(&round, attach: attach)
        await removeTree(paths)

        let reason = outcome.failure.map { Self.withoutCredentials(PRBodyBuilder.scrub($0)) }
        let findingsPath = outcome.findings == nil
            ? nil : ".workbench/reviews/\(folder.lastPathComponent)/\(paths.answer.lastPathComponent)"
        return PRReviewResult(
            round: 1, pr: number, maxRounds: 0, headSHA: round.reviewedSHA ?? tip, verdict: outcome.verdict,
            failure: reason, findingsPath: findingsPath, findings: outcome.findings, warnings: outcome.warnings)
    }

    /// The pull request's branch, base and text, refused unless it is open and its branch is on origin.
    func pullRequestInfo(_ number: Int, gh: GitRunner) async throws -> PullRequestInfo {
        let fields = "headRefName,baseRefName,title,body,state,isCrossRepository"
        let result = try? await gh.run(["pr", "view", String(number), "--json", fields], in: project.root)
        guard let result, result.succeeded,
            let object = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any],
            let branch = object["headRefName"] as? String, let base = object["baseRefName"] as? String
        else {
            let why = result.map { Self.withoutCredentials($0.stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
            throw PRReviewRefusal.pullRequestUnreadable(number, why.flatMap { $0.isEmpty ? nil : $0 } ?? "no answer")
        }
        guard object["state"] as? String == "OPEN" else {
            throw PRReviewRefusal.notReviewable(number, "it is not open")
        }
        guard object["isCrossRepository"] as? Bool != true else {
            throw PRReviewRefusal.notReviewable(number, "it comes from a fork, so its branch is not on origin")
        }
        guard SafeNames.isBranchName(branch), SafeNames.isBranchName(base) else {
            throw PRReviewRefusal.notReviewable(number, "its branch name is not one Workbench passes to git")
        }
        return PullRequestInfo(
            branch: branch, base: base, title: PRBodyBuilder.scrub(object["title"] as? String ?? ""),
            body: PRBodyBuilder.scrub(object["body"] as? String ?? ""))
    }
}
