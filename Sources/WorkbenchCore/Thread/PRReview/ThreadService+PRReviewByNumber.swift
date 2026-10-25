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
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> PRReviewResult {
        // `gh` reads the repository of the directory it runs in, which is where origin is fetched from. A `GH_REPO` in
        // the person's shell would point it at another one.
        let gh = GitRunner(
            executable: gh.executable, environment: gh.environment.filter { $0.key != "GH_REPO" }, timeout: gh.timeout)
        let reviews = project.workbenchDirectory.appendingPathComponent("reviews", isDirectory: true)
        // One review at a time in a project, as for threads: reviews share this repository's `FETCH_HEAD`, and a
        // killed one's leftovers cannot be told from a live one's without a holder. The kernel drops the lock with
        // the process, so there is never a stale one.
        guard let lock = FolderLock(folder: reviews) else { throw PRReviewRefusal.busy }
        defer { lock.release() }
        // What a killed review left, for any pull request or commit: ended before anything is read or refused.
        await recoverPullRequestLeftovers(in: reviews)

        let info = try await pullRequestInfo(number, gh: gh)
        let tip = try await originBranchTip(info.branch)
        let folder = reviews.appendingPathComponent("pr-\(number)-\(tip.prefix(7))", isDirectory: true)
        let paths = PRReviewPaths(folder: folder, round: 1)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !again, FileManager.default.fileExists(atPath: paths.answer.path) {
            throw PRReviewRefusal.alreadyReviewed(round: 1)
        }

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

    /// Ends what a killed review left in any pull request's folder. Called with the reviews lock held, so none is live.
    func recoverPullRequestLeftovers(in reviews: URL) async {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: reviews.path)) ?? []
        for name in names where name.hasPrefix("pr-") {
            let folder = reviews.appendingPathComponent(name, isDirectory: true)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue
            else { continue }
            await removeTree(PRReviewPaths(folder: folder, round: 1))
        }
    }

    /// `owner/name` of origin when it is a GitHub URL (`git@github.com:o/n.git`, `https://github.com/o/n`), with the
    /// host in front when it is not github.com; nil for anything else, such as a local path.
    static func repositoryName(ofOrigin url: String) -> String? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        var path: String
        if let match = text.wholeMatch(of: #/[A-Za-z0-9._-]+@([A-Za-z0-9.-]+):([^/].*)/#) {
            (host, path) = (String(match.1), String(match.2))
        } else if let match = text.wholeMatch(of: #/(?:https|ssh)://(?:[^@/]+@)?([A-Za-z0-9.-]+)(?::[0-9]+)?/(.+)/#) {
            (host, path) = (String(match.1), String(match.2))
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.wholeMatch(of: #/[A-Za-z0-9._-]+/#) != nil }) else { return nil }
        return (host == "github.com" ? "" : host + "/") + parts.joined(separator: "/")
    }

    private static func describe(_ error: Error) -> String {
        switch error as? GitError {
        case .timedOut(_, let seconds): "it did not finish in \(Int(seconds))s"
        case .launchFailed(let reason): "it could not be started (\(reason))"
        case .toolNotFound(let name): "\(name) was not found"
        default: "\(error)"
        }
    }

    /// The pull request's branch, base and text, refused unless it is open and its branch is on origin.
    func pullRequestInfo(_ number: Int, gh: GitRunner, originURL: String? = nil) async throws -> PullRequestInfo {
        let fields = "headRefName,baseRefName,title,body,state,isCrossRepository"
        // Said outright when origin is a GitHub URL, so a `gh` default for another remote cannot answer for it.
        var url = originURL
        if url == nil, let origin = try? await git.run(["remote", "get-url", "origin"], in: project.root), origin.succeeded {
            url = origin.stdout
        }
        let repo = url.flatMap { Self.repositoryName(ofOrigin: $0) }
        let repoArgs = repo.map { ["--repo", $0] } ?? []
        // The error is kept: "no answer" for a launch failure or a timeout hid which of them it was.
        var runError: Error?
        let result: GitResult?
        do {
            result = try await gh.run(["pr", "view", String(number), "--json", fields] + repoArgs, in: project.root)
        } catch {
            runError = error
            result = nil
        }
        guard let result, result.succeeded,
            let object = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any],
            let branch = object["headRefName"] as? String, let base = object["baseRefName"] as? String
        else {
            let stderr = result.map { Self.withoutCredentials($0.stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
            let why = stderr.flatMap { $0.isEmpty ? nil : $0 }
                ?? runError.map { Self.describe($0) }
                ?? result.map { $0.succeeded ? "its answer was not the expected JSON" : "it exited \($0.status) with no message" }
                ?? "no answer"
            throw PRReviewRefusal.pullRequestUnreadable(number, why)
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

/// An exclusive, non-blocking lock on a review folder, held while a review of that commit runs. It is the kernel's
/// `flock`, so a review that is killed releases it and no stale lock needs clearing.
final class FolderLock: @unchecked Sendable {
    // The descriptor is set once in `init` and closed once by `release`; nothing else touches it.
    private var descriptor: Int32

    /// Nil when another review holds the lock or the folder cannot be made.
    init?(folder: URL) {
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let fd = open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
