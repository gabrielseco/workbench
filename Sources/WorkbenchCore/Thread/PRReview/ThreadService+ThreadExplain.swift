import Foundation

extension ThreadService {
    /// Explains review thread `thread` of pull request `number`, with the plumbing of `explainPullRequest`: the pull request
    /// read with `gh`, the thread read with `gh api graphql` (a query, never a mutation), the head fetched from origin and
    /// checked out in a throwaway worktree, and the review agent run read-only, asked for JSON with `reasoning` and
    /// `proposed_fix`. Nothing is committed, pushed, replied, resolved or recorded in a thread's log.
    ///
    /// Refused before anything is spawned when the pull request is not open or from a fork (`PRReviewRefusal`), or the
    /// thread does not exist or is on another pull request (`ThreadExplainRefusal`).
    public func explainReviewThread(
        number: Int, thread id: String, config: Config, gh: GitRunner, codexPath: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = PRReview.timeout,
        capacityBackoff: @escaping @Sendable (Int) -> TimeInterval = { TimeInterval($0 * 20) },
        stopRequested: @escaping @Sendable () -> Bool = { false },
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> ThreadExplainResult {
        guard ThreadExplain.isThreadID(id) else { throw ThreadExplainRefusal.unknownThread(id) }
        // As for a review: `gh` reads the repository of the directory it runs in, never a `GH_REPO` from the shell.
        let gh = GitRunner(
            executable: gh.executable, environment: gh.environment.filter { $0.key != "GH_REPO" }, timeout: gh.timeout)
        let reviews = project.workbenchDirectory.appendingPathComponent("reviews", isDirectory: true)
        let explains = project.workbenchDirectory.appendingPathComponent(PRExplain.folderName, isDirectory: true)
        let folder = explains.appendingPathComponent(ThreadExplain.folderName(pr: number, thread: id), isDirectory: true)
        let paths = PRReviewPaths(folder: folder, round: 1)
        // The reviews' lock: the head is fetched into the same `FETCH_HEAD` as a review by number. It is held for the
        // setup only, and let go when the agent starts, so threads are explained side by side.
        guard let lock = FolderLock(folder: reviews) else { throw PRReviewRefusal.busy }
        defer { lock.release() }
        // Ends what a killed run left, this thread's included; a live run's folder is locked and is skipped.
        await recoverByNumberLeftovers()

        let originURL = (try? await git.run(["remote", "get-url", "origin"], in: project.root)).flatMap {
            $0.succeeded ? $0.stdout : nil
        }
        let info = try await pullRequestInfo(number, gh: gh, originURL: originURL)
        let thread = try await reviewThread(id, pr: number, gh: gh, originURL: originURL)
        let tip = try await originBranchTip(info.branch)
        func result(
            _ answer: (reasoning: String, proposedFix: String)? = nil, failure: String? = nil, transcript: String? = nil,
            warnings: [String] = []
        ) -> ThreadExplainResult {
            ThreadExplainResult(
                pr: number, thread: id, headSHA: tip, reasoning: answer?.reasoning, proposedFix: answer?.proposedFix,
                failure: failure, transcriptPath: transcript, warnings: warnings)
        }

        // This run's own lock, taken once the run is real (a refusal leaves no folder) and held to the end: the same
        // thread twice is refused, and another run's recovery leaves this folder alone while the agent works.
        guard let live = FolderLock(folder: folder) else { throw PRReviewRefusal.busy }
        defer { live.release() }
        // A previous run's answer must not stand in for this one's.
        try? FileManager.default.removeItem(at: paths.answer)
        let settings = PRReviewSettings(
            codexPath: codexPath, environment: environment, timeout: timeout,
            capacityBackoff: capacityBackoff, stopRequested: stopRequested)
        var round = PRReviewRound(
            id: "pr-\(number)", task: .explainThread(thread), stage: .prReview(config), pr: number, branch: info.branch,
            base: info.base, recordedBase: nil, goal: "# \(info.title)\n\n\(info.body)",
            goalRest: "pull request #\(number) on GitHub", tip: tip, paths: paths, config: config, settings: settings)
        round.setupDone = { lock.release() }
        var warnings: [String] = []
        if thread.truncated {
            warnings.append("the thread has more than \(ThreadExplain.maxComments) comments; the agent read the first ones")
        }
        let outcome = await runRound(&round, attach: attach)
        await removeTree(paths)
        warnings += outcome.warnings

        let transcript = FileManager.default.fileExists(atPath: paths.transcript.path)
            ? ".workbench/\(PRExplain.folderName)/\(folder.lastPathComponent)/\(paths.transcript.lastPathComponent)" : nil
        if let failure = outcome.failure {
            let reason = Self.withoutCredentials(PRBodyBuilder.scrub(failure))
            return result(failure: reason, transcript: transcript, warnings: warnings)
        }
        guard let text = outcome.findings, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result(
                failure: "\(round.agent.provider) wrote an empty answer", transcript: transcript, warnings: warnings)
        }
        guard let answer = ThreadExplain.answer(text) else {
            return result(
                failure: "\(round.agent.provider)'s answer is not a JSON object with non-empty `reasoning` and "
                    + "`proposed_fix` strings", transcript: transcript, warnings: warnings)
        }
        return result(answer, transcript: transcript, warnings: warnings)
    }

    /// The review thread `id`, every comment in order (up to `ThreadExplain.maxComments`), refused unless GitHub has it
    /// and it is on pull request `pr` of origin's repository.
    func reviewThread(_ id: String, pr: Int, gh: GitRunner, originURL: String?) async throws -> ReviewThreadContext {
        let repo = originURL.flatMap { Self.repositoryName(ofOrigin: $0) }
        let parts = repo?.split(separator: "/").map(String.init) ?? []
        // `host/owner/name` for a GitHub that is not github.com: `gh api` is pointed at that host.
        let hostArgs = parts.count == 3 ? ["--hostname", parts[0]] : []
        let expected = parts.count >= 2 ? parts.suffix(2).joined(separator: "/") : nil

        var thread: ReviewThreadContext?
        var cursor: String?
        for _ in 0..<ThreadExplain.maxPages {
            var args = ["api", "graphql"] + hostArgs + ["-f", "query=\(ThreadExplain.query)", "-f", "id=\(id)"]
            if let cursor { args += ["-f", "after=\(cursor)"] }
            let ran: GitResult
            do { ran = try await gh.run(args, in: project.root) } catch {
                throw ThreadExplainRefusal.unreadable(id, "\(error)")
            }
            guard ran.succeeded else {
                let stderr = Self.withoutCredentials(ran.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                // GitHub's answer for an id it has no node for, of any shape.
                if stderr.contains("Could not resolve to a node") || ran.stdout.contains("Could not resolve to a node") {
                    throw ThreadExplainRefusal.unknownThread(id)
                }
                throw ThreadExplainRefusal.unreadable(id, stderr.isEmpty ? "it exited \(ran.status) with no message" : stderr)
            }
            switch ThreadExplain.parsePage(ran.stdout, id: id) {
            case .failure(.notAThread): throw ThreadExplainRefusal.unknownThread(id)
            case .failure(.malformed): throw ThreadExplainRefusal.unreadable(id, "its answer was not the expected JSON")
            case .success(let page):
                if thread == nil {
                    let sameRepo = expected == nil || page.repository == nil
                        || page.repository?.lowercased() == expected?.lowercased()
                    guard page.thread.pr == pr, sameRepo else {
                        let its = "pull request #\(page.thread.pr)" + (page.repository.map { " of \($0)" } ?? "")
                        throw ThreadExplainRefusal.otherPullRequest(thread: id, pr: pr, its: its)
                    }
                    thread = page.thread
                } else {
                    thread?.comments += page.thread.comments
                }
                cursor = page.nextCursor
            }
            if cursor == nil { break }
        }
        guard var thread else { throw ThreadExplainRefusal.unknownThread(id) }
        thread.truncated = cursor != nil
        // GitHub lists them oldest first; sorted again so the order never rests on that. Equal times keep their place.
        thread.comments = thread.comments.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map(\.element)
        return thread
    }
}
