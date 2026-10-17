import Foundation

extension ThreadService {
    /// Runs one review round of the thread's pull request and records it.
    ///
    /// Codex is started by Workbench, read-only, on a throwaway checkout of the pull request's head. The round
    /// is on record before anything runs (`pr_review.started`), exactly one `pr_review.finished` follows it, and
    /// the count of rounds is the number of `started` events for this pull request, so only the log can say how
    /// many were spent. The thread's log is held from the checks to the record, so a run, a judge or a second
    /// review cannot start beside it (they are refused as busy).
    ///
    /// - Parameters:
    ///   - codexPath: `codex` by name (looked up on PATH) or by path.
    ///   - capacityBackoff: seconds to wait after the nth "at capacity" answer.
    ///   - attach: called with each running `codex`, so the caller can stop it (Ctrl-C).
    ///   - stopRequested: polled between tries and before `codex` starts, so a stop also ends the parts of a round
    ///     that run no `codex`.
    public func prReview(
        id: String, config: Config, again: Bool = false, codexPath: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = PRReview.timeout,
        capacityBackoff: @escaping @Sendable (Int) -> TimeInterval = { TimeInterval($0 * 20) },
        stopRequested: @escaping @Sendable () -> Bool = { false },
        attach: @Sendable (ProcessRun) -> Void = { _ in }
    ) async throws -> PRReviewResult {
        let settings = PRReviewSettings(
            codexPath: codexPath, environment: environment, timeout: timeout,
            capacityBackoff: capacityBackoff, stopRequested: stopRequested)
        return try await reviewStage(.prReview(config), id: id, config: config, again: again, settings: settings, attach: attach)
    }

    /// Runs one round of `stage` on the thread's pull request; `prReview` is this for the `pr-review` stage.
    func reviewStage(
        _ stage: ReviewStage, id: String, config: Config, again: Bool, settings: PRReviewSettings,
        attach: @Sendable (ProcessRun) -> Void
    ) async throws -> PRReviewResult {
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        do {
            return try await withLog(id) { log in
                try await self.reviewStageLocked(
                    stage, id: id, log: log, config: config, again: again, settings: settings, attach: attach)
            }
        } catch EventLogError.alreadyOpen { throw PRReviewRefusal.busy }
    }

    private func reviewStageLocked(
        _ stage: ReviewStage, id: String, log: EventLogWriter, config: Config, again: Bool, settings: PRReviewSettings,
        attach: @Sendable (ProcessRun) -> Void
    ) async throws -> PRReviewResult {
        // A round that was killed leaves its `codex` and its checkout behind. This process holds the thread's log, so
        // none of them is live: end them now, before any refusal can leave them for good.
        await recoverLeftovers(in: project.threadDirectory(id).appendingPathComponent(stage.folder))
        let events = (try? EventLogReader.read(at: project.eventsURL(id)))?.events ?? []
        let state = ThreadState.derive(from: events, id: id)
        guard let opened = events.last(where: { $0.kind == .prOpened }),
            let pr = opened.data["number"]?.intValue, let branch = opened.data["branch"]?.stringValue,
            let base = opened.data["base"]?.stringValue, SafeNames.isBranchName(branch), SafeNames.isBranchName(base)
        else { throw PRReviewRefusal.noPullRequest }

        // Counted over the whole tree of follow-up threads of this pull request, so starting a follow-up cannot reset it.
        let family = self.family(of: id)
        let rounds = reviewStartedCount(stage.events, family: family, pr: pr)
        let maxRounds = stage.config.maxRounds
        if rounds >= maxRounds { throw PRReviewRefusal.capReached(pr: pr, rounds: rounds, max: maxRounds) }

        let goal: String
        do { goal = try String(contentsOf: project.goalURL(id), encoding: .utf8) } catch {
            throw PRReviewRefusal.goalUnreadable("\(error.localizedDescription)")
        }
        let tip = try await originBranchTip(branch)
        if !again, let last = reviewRecords(stage.events, family: family, pr: pr).last, last.ok, last.headSHA == tip {
            throw PRReviewRefusal.alreadyReviewed(round: last.round)
        }

        let round = rounds + 1
        let paths = PRReviewPaths(folder: project.threadDirectory(id).appendingPathComponent(stage.folder), round: round)
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        let argv = PRReview.arguments(tree: paths.tree.path, answer: paths.answer.path, brief: paths.brief.path)
        let recordedBase = events.last { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue

        // The attempt is on record before anything is spent, and this process is the thread's live holder while it
        // runs (`stop` reaches it; a run or another review is refused).
        try await log.append(
            stage.events.started, turn: state.lastTurn,
            data: [
                "round": .int(round), "pr": .int(pr), "head_sha": .string(tip),
                "argv": .array(PRDescriber.displayArguments(argv).map { .string($0) }),
            ])
        try? writeHolderMarker(id)
        defer { try? FileManager.default.removeItem(at: project.runnerURL(id)) }

        var context = PRReviewRound(
            id: id, stage: stage, pr: pr, branch: branch, base: base, recordedBase: recordedBase, goal: goal, tip: tip,
            paths: paths, config: config, settings: settings)
        let outcome = await runRound(&context, attach: attach)
        await removeTree(paths)
        let findings = outcome.findings
        let findingsPath = findings == nil ? nil : "\(stage.folder)/\(paths.answer.lastPathComponent)"
        let transcript =
            FileManager.default.fileExists(atPath: paths.transcript.path)
            ? "\(stage.folder)/\(paths.transcript.lastPathComponent)" : nil
        return try await recordRound(
            log, stage: stage, turn: state.lastTurn, round: round, pr: pr, maxRounds: maxRounds, outcome: outcome,
            sha: context.reviewedSHA ?? tip, findingsPath: findingsPath, transcript: transcript)
    }

    // MARK: A round

    private func runRound(_ round: inout PRReviewRound, attach: @Sendable (ProcessRun) -> Void) async -> PRReviewOutcome {
        var outcome = PRReviewOutcome()
        if let warning = round.stage.notYetUsedWarning { outcome.warnings.append(warning) }
        let paths = round.paths
        let sha = round.tip
        round.reviewedSHA = sha
        if let reason = await fetchBranch(round) { return outcome.failed(reason) }
        switch await pinBase(round) {
        case .failure(let reason): return outcome.failed(reason)
        case .success(let value): round.baseSHA = value
        }
        guard let baseSHA = round.baseSHA else { return outcome.failed("the base commit is not known") }

        let add = try? await git.run(["worktree", "add", "--detach", paths.tree.path, sha], in: project.root)
        guard let add, add.succeeded else {
            return outcome.failed("the checkout of the pull request could not be made: \(add?.stderr.firstLine ?? "git failed")")
        }
        let diffText: String
        let truncated: Bool
        switch await diff(baseSHA: baseSHA, sha: sha) {
        case .failure(let reason): return outcome.failed(reason)
        case .success(let value): (diffText, truncated) = value
        }
        try? diffText.write(to: paths.diff, atomically: true, encoding: .utf8)

        var input = PRReviewInput(
            pr: round.pr, branch: round.branch, base: round.base, headSHA: sha, baseSHA: baseSHA,
            goal: Self.bounded(round.goal, limit: PRReview.goalLimit, rest: project.goalURL(round.id).path),
            instructions: nil, checklist: nil, checklistPath: nil,
            diffPath: paths.diff.path, diffTruncated: truncated)
        if round.config.projectInstructions {
            input.instructions = await ProjectInstructions.load(git: git, repo: project.root, commit: baseSHA)?.text
        }
        if let path = round.stage.config.checklist {
            if let text = Self.readChecklist(path, in: paths.tree) {
                input.checklist = text
                input.checklistPath = path
            } else {
                outcome.warnings.append("the checklist \(path) is not a readable file in the pull request; reviewed without it")
            }
        }
        do { try round.stage.brief(for: input).write(to: paths.brief, atomically: true, encoding: .utf8) } catch {
            return outcome.failed("the review brief could not be written: \(error.localizedDescription)")
        }

        guard let codex = ExecutableResolver.resolve(round.settings.codexPath, searchPath: round.settings.environment["PATH"])
        else { return outcome.failed("`\(round.settings.codexPath)` was not found: install Codex or put it on PATH") }

        if round.settings.stopRequested() { return outcome.failed("the review was stopped") }
        let transcript = await runCodex(
            codex, round: round, attach: attach,
            argv: PRReview.arguments(tree: paths.tree.path, answer: paths.answer.path, brief: paths.brief.path))
        try? transcript.text.write(to: paths.transcript, atomically: true, encoding: .utf8)
        if let problem = transcript.problem { return outcome.failed(problem, answer: Self.readAnswer(paths.answer)) }

        if Self.answerSize(paths.answer) > PRReview.answerLimit {
            return outcome.failed(
                "the answer is larger than \(PRReview.answerLimit / 1024) KiB, so its last line cannot be trusted; "
                    + "it was not accepted", answer: Self.readAnswer(paths.answer))
        }
        guard let answer = Self.readAnswer(paths.answer) else {
            return outcome.failed("codex ended without writing an answer")
        }
        guard let verdict = PRReview.parseVerdict(answer) else {
            return outcome.failed(
                "the answer does not end in exactly one `\(PRReview.cleanLine)` or `\(PRReview.fixLine)` line", answer: answer)
        }
        outcome.verdict = verdict
        outcome.findings = answer
        return outcome
    }

    /// Runs Codex up to `attempts` times while it answers that its model is at capacity.
    private func runCodex(
        _ codex: URL, round: PRReviewRound, attach: @Sendable (ProcessRun) -> Void, argv: [String]
    ) async -> (text: String, problem: String?) {
        var transcript = ""
        for attempt in 1...PRReview.attempts {
            if round.settings.stopRequested() { return (transcript, "the review was stopped") }
            try? FileManager.default.removeItem(at: round.paths.answer)
            var request = SpawnRequest(
                executable: codex, arguments: argv, environment: PRReview.environment(from: round.settings.environment),
                workingDirectory: round.paths.tree, timeout: round.settings.timeout)
            request.maxLineBytes = 1 << 20
            request.maxOutputBytes = PRReview.transcriptLimit
            let run: ProcessRun
            do { run = try ProcessRunner.start(request) } catch {
                return (transcript, "codex could not be started: \(error)")
            }
            attach(run)
            var lines: [String] = []
            var exit: ProcessExit?
            for await event in run.events {
                switch event {
                case .line(let line): lines.append(line)
                case .exited(let e): exit = e
                case .started, .oversizedLine: break
                }
            }
            let tail = exit?.stderrTail ?? ""
            transcript += "--- attempt \(attempt) ---\n" + lines.joined(separator: "\n")
            transcript += "\n--- stderr (end) ---\n" + tail + "\n"
            let answer = Self.readAnswer(round.paths.answer)
            if answer == nil, PRReview.atCapacity(tail) || PRReview.atCapacity(lines.joined(separator: "\n")) {
                if attempt < PRReview.attempts {
                    let stopped = await Self.sleep(round.settings.capacityBackoff(attempt), stop: round.settings.stopRequested)
                    if stopped { return (transcript, "the review was stopped") }
                    continue
                }
                return (transcript, "codex's model was at capacity \(PRReview.attempts) times; no review. Try again later.")
            }
            return (transcript, Self.codexProcessProblem(exit, timeout: round.settings.timeout))
        }
        return (transcript, "codex did not answer")
    }

    // MARK: Git

    /// The commit `origin` has for a branch.
    func originBranchTip(_ branch: String) async throws -> String {
        let result: GitResult
        do { result = try await git.run(["ls-remote", "origin", "refs/heads/\(branch)"], in: project.root) } catch {
            throw PRReviewRefusal.originUnreadable("\(error)")
        }
        guard result.succeeded else {
            throw PRReviewRefusal.originUnreadable(Self.withoutCredentials(result.stderr.firstLine))
        }
        guard let sha = Self.firstSHA(result.stdout) else { throw PRReviewRefusal.branchGone(branch) }
        return sha
    }

    /// Brings the pull request's branch into this repository and checks it is still the commit the round began with.
    /// The branch on origin is the pull request's head the moment a push lands; GitHub's own `pull/<n>/head` and its API
    /// lag behind it, so they are not read.
    private func fetchBranch(_ round: PRReviewRound) async -> String? {
        let fetch = try? await git.run(
            ["fetch", "--quiet", "--no-tags", "origin", "refs/heads/\(round.branch)"], in: project.root)
        guard let fetch, fetch.succeeded else {
            let why = Self.withoutCredentials(fetch?.stderr.firstLine ?? "git failed")
            return "the pull request's branch could not be fetched: \(why)"
        }
        let head = try? await git.run(["rev-parse", "--verify", "FETCH_HEAD^{commit}"], in: project.root)
        guard let head, head.succeeded, Self.firstSHA(head.stdout) == round.tip else {
            return "the branch moved while the review was starting; nothing was reviewed. Run it again."
        }
        return nil
    }

    /// The commit of the base branch the pull request is compared with, fetched now so that the diff and the project
    /// instructions are the ones GitHub shows and not those of a stale `origin/<base>`. When origin no longer has the
    /// branch, the commit the thread was cut from.
    private func pinBase(_ round: PRReviewRound) async -> Result<String, PRReviewFailure> {
        guard let remote = try? await git.run(["ls-remote", "origin", "refs/heads/\(round.base)"], in: project.root),
            remote.succeeded
        else { return .failure(PRReviewFailure("origin could not be read, so the base branch is not known")) }
        if Self.firstSHA(remote.stdout) != nil {
            let fetch = try? await git.run(
                ["fetch", "--quiet", "--no-tags", "origin", "refs/heads/\(round.base)"], in: project.root)
            let head = try? await git.run(["rev-parse", "--verify", "FETCH_HEAD^{commit}"], in: project.root)
            guard let fetch, fetch.succeeded, let head, head.succeeded,
                let sha = Self.firstSHA(head.stdout)
            else {
                let why = Self.withoutCredentials(fetch?.stderr.firstLine ?? "git failed")
                return .failure(PRReviewFailure("the base branch \(round.base) could not be fetched: \(why)"))
            }
            return .success(sha)
        }
        let fullSHA = #"^[0-9a-f]{40}([0-9a-f]{24})?$"#
        if let recorded = round.recordedBase, recorded.range(of: fullSHA, options: .regularExpression) != nil {
            return .success(recorded)
        }
        return .failure(
            PRReviewFailure("origin has no \(round.base) and no base commit is recorded: no diff can be made"))
    }

    private func diff(baseSHA: String, sha: String) async -> Result<(String, Bool), PRReviewFailure> {
        let result = try? await git.run(["diff", "--no-ext-diff", "--no-color", "\(baseSHA)...\(sha)"], in: project.root)
        guard let result, result.succeeded else {
            let why = result?.stderr.firstLine ?? "git failed"
            return .failure(PRReviewFailure("the diff of the pull request could not be read: \(why)"))
        }
        let cut = result.stdout.utf8.count > PRReview.diffLimit
        return .success((cut ? Self.cut(result.stdout, PRReview.diffLimit) : result.stdout, cut))
    }

    /// Ends what an earlier, killed round left: a `codex` still running in the folder, a registered checkout, a saved diff.
    private func recoverLeftovers(in folder: URL) async {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        OrphanSweeper.sweep(inside: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("round-") && name.hasSuffix(".tree") {
            let tree = folder.appendingPathComponent(name)
            _ = try? await git.run(["worktree", "remove", "--force", tree.path], in: project.root)
            try? FileManager.default.removeItem(at: tree)
        }
        for name in names where name.hasPrefix("round-") && name.hasSuffix(".diff.patch") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        _ = try? await git.run(["worktree", "prune"], in: project.root)
    }

    /// Removes the throwaway checkout and the saved diff. Never forced on anything but its own folder.
    private func removeTree(_ paths: PRReviewPaths) async {
        // A child Codex started in a new session and left can outlive the runner's own sweep; find it by its working
        // directory while the checkout is still there.
        OrphanSweeper.sweep(inside: paths.folder)
        if FileManager.default.fileExists(atPath: paths.tree.path) {
            _ = try? await git.run(["worktree", "remove", "--force", paths.tree.path], in: project.root)
            try? FileManager.default.removeItem(at: paths.tree)
            _ = try? await git.run(["worktree", "prune"], in: project.root)
        }
        try? FileManager.default.removeItem(at: paths.diff)
    }

    // MARK: Record

    private func recordRound(
        _ log: EventLogWriter, stage: ReviewStage, turn: Int, round: Int, pr: Int, maxRounds: Int,
        outcome: PRReviewOutcome, sha: String, findingsPath: String?, transcript: String?
    ) async throws -> PRReviewResult {
        let reason = outcome.failure.map { Self.withoutCredentials(PRBodyBuilder.scrub($0)) }
        var data: [String: JSONValue] = [
            "round": .int(round), "pr": .int(pr), "head_sha": .string(sha), "ok": .bool(outcome.verdict != nil),
            "verdict": outcome.verdict.map { .string($0.rawValue) } ?? .null,
        ]
        if let transcript { data["transcript_path"] = .string(transcript) }
        if let findingsPath { data["findings_path"] = .string(findingsPath) }
        if let reason { data["reason"] = .string(reason) }
        try await log.append(stage.events.finished, turn: turn, data: .object(data))
        return PRReviewResult(
            round: round, pr: pr, maxRounds: maxRounds, headSHA: sha, verdict: outcome.verdict, failure: reason,
            findingsPath: findingsPath, findings: outcome.findings, warnings: outcome.warnings)
    }

    // MARK: Small helpers

    static func codexProcessProblem(_ exit: ProcessExit?, timeout: TimeInterval) -> String? {
        guard let exit else { return "codex did not report how it ended" }
        switch exit.cause {
        case .stopped: return "the review was stopped"
        case .timedOut: return "codex did not finish within \(Int(timeout))s"
        case .natural: break
        }
        switch exit.termination {
        case .exited(0): return nil
        case .exited(let code):
            let tail = exit.stderrTail.firstLine
            return "codex exited with status \(code)" + (tail.isEmpty ? "" : ": \(tail)")
        case .signaled(let signal): return "codex was ended by signal \(signal)"
        case .lost: return "codex ended in a way that was not recorded"
        }
    }

    static func firstSHA(_ output: String) -> String? {
        guard let first = output.split(whereSeparator: \.isNewline).first,
            let sha = first.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
            sha.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil
        else { return nil }
        return String(sha)
    }

    /// Sleeps in short slices so a stop is noticed; true when one was requested.
    static func sleep(_ seconds: TimeInterval, stop: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, seconds))
        while Date() < deadline {
            if stop() { return true }
            try? await Task.sleep(nanoseconds: UInt64(min(0.1, max(0.005, deadline.timeIntervalSinceNow)) * 1e9))
        }
        return stop()
    }

    static func answerSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    static func cut(_ text: String, _ limit: Int) -> String {
        text.utf8.count > limit ? String(decoding: text.utf8.prefix(limit), as: UTF8.self) : text
    }

    /// Codex's answer file, bounded, nil when it is missing or empty.
    static func readAnswer(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: PRReview.answerLimit), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// `text` cut at `limit` bytes, with a line saying so and where to read the rest: a cut the reviewer is not told
    /// about could hide the criteria that matter.
    static func bounded(_ text: String, limit: Int, rest: String) -> String {
        guard text.utf8.count > limit else { return text }
        return cut(text, limit) + "\n[cut here at \(limit / 1024) KiB: the rest is at \(rest)]"
    }

    /// The checklist from the pull request's checkout: a regular file that stays inside it, bounded.
    static func readChecklist(_ path: String, in tree: URL) -> String? {
        let root = tree.resolvingSymlinksInPath().path
        let file = tree.appendingPathComponent(path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root + "/"),
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: PRReview.checklistLimit + 1) else { return nil }
        return bounded(String(decoding: data, as: UTF8.self), limit: PRReview.checklistLimit, rest: "\(path) in the checkout")
    }
}

// MARK: Value types

struct PRReviewSettings: Sendable {
    var codexPath: String
    var environment: [String: String]
    var timeout: TimeInterval
    var capacityBackoff: @Sendable (Int) -> TimeInterval
    var stopRequested: @Sendable () -> Bool
}

struct PRReviewPaths: Sendable {
    var folder: URL
    var tree: URL
    var brief: URL
    var diff: URL
    var answer: URL
    var transcript: URL

    init(folder: URL, round: Int) {
        self.folder = folder
        tree = folder.appendingPathComponent("round-\(round).tree")
        brief = folder.appendingPathComponent("round-\(round).brief.md")
        diff = folder.appendingPathComponent("round-\(round).diff.patch")
        answer = folder.appendingPathComponent("round-\(round).findings.md")
        transcript = folder.appendingPathComponent("round-\(round).transcript.txt")
    }
}

struct PRReviewRound: Sendable {
    var id: String
    var stage: ReviewStage
    var pr: Int
    var branch: String
    var base: String
    var recordedBase: String?
    var goal: String
    var tip: String
    var paths: PRReviewPaths
    var config: Config
    var settings: PRReviewSettings
    /// The commit that was reviewed: the branch tip on origin when the round began.
    var reviewedSHA: String?
    /// The base branch's commit the diff and the instructions come from.
    var baseSHA: String?
}

struct PRReviewFailure: Error, Sendable {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

struct PRReviewOutcome: Sendable {
    var verdict: PRReviewVerdict?
    var failure: String?
    var findings: String?
    var warnings: [String] = []

    mutating func failed(_ reason: String, answer: String? = nil) -> PRReviewOutcome {
        failure = reason
        findings = answer
        return self
    }

    mutating func failed(_ reason: PRReviewFailure) -> PRReviewOutcome { failed(reason.reason) }
}

private extension String {
    /// The first non-empty line, for a one-line reason.
    var firstLine: String {
        split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}
