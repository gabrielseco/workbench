import Foundation

/// A proposed change to the pull request a thread updates, ready to show and to apply.
public struct PRRefreshProposal: Sendable, Equatable {
    public struct Change: Sendable, Equatable {
        public var heading: String
        public var before: String
        public var after: String
    }

    public var number: Int
    /// The text the proposal was made from; applying refuses when the pull request no longer has it.
    public var current: PRText
    public var updated: PRText
    public var titleChanged: Bool
    public var changes: [Change]

    /// The answer left everything as it was.
    public var isEmpty: Bool { !titleChanged && changes.isEmpty }

    /// What would change, one line per row: the title, then each section as removed and added lines.
    public func render() -> [String] {
        var lines: [String] = []
        if titleChanged {
            lines.append("title:")
            lines.append("  - \(current.title)")
            lines.append("  + \(updated.title)")
        }
        for change in changes {
            lines.append("\(change.heading):")
            let before = change.before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let after = change.after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for step in after.difference(from: before).inferringMoves() {
                if case .remove(_, let text, _) = step { lines.append("  - \(text)") }
            }
            // Removals are listed first, then the lines that are new, so a rewritten table row reads as a pair.
            for step in after.difference(from: before).inferringMoves() {
                if case .insert(_, let text, _) = step { lines.append("  + \(text)") }
            }
        }
        return lines
    }
}

/// What the refresh turn produced, or why `ship` leaves the pull request text alone.
public struct PRRefreshResult: Sendable, Equatable {
    public var proposal: PRRefreshProposal?
    public var fallback: String?
}

extension ThreadService {
    /// Asks a read-only turn whether the pull request's text still matches the thread's work. Like
    /// `describePR` it never throws for a failed turn: the reason comes back as `fallback`, because shipping
    /// must not depend on it. Writes `pr.refreshed` with `stage: proposed` and how it went.
    public func proposePRRefresh(
        plan: ShipPlan, config: Config, environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = PRDescriber.timeout
    ) async throws -> PRRefreshResult {
        guard let pr = plan.pullRequest else {
            return try await recordProposal(plan, fail: "this thread has no pull request to update")
        }
        guard let current = pr.text else {
            return try await recordProposal(plan, fail: "GitHub did not return the pull request's text")
        }
        let events = (try? EventLogReader.read(at: project.eventsURL(plan.id)))?.events ?? []
        let goal: Goal
        do {
            goal = try GoalFile.parse(String(contentsOf: project.goalURL(plan.id), encoding: .utf8)).goal
        } catch { return try await recordProposal(plan, fail: "the goal could not be read") }
        let state = ThreadState.derive(from: events, id: plan.id)

        // What the thread added, from the commit it was cut at; the branch's own name can move.
        let cutAt = events.last(where: { $0.kind == .worktreeCreated })?.data["base_commit"]?.stringValue ?? plan.base
        let diff = try? await git.run(["diff", "--no-ext-diff", "--no-color", "\(cutAt)...\(plan.head)"], in: plan.worktree)
        let log = try? await git.run(["log", "--format=%s", "\(cutAt)..\(plan.head)"], in: plan.worktree)
        guard let diff, diff.succeeded else { return try await recordProposal(plan, fail: "the diff could not be read") }
        let cut = diff.stdout.utf8.count > PRDescriber.diffLimit
        let diffText = cut ? String(decoding: diff.stdout.utf8.prefix(PRDescriber.diffLimit), as: UTF8.self) : diff.stdout

        let input = PRRefreshInput(
            goal: goal, notes: state.review.notes.map(\.text), turnResult: state.review.turnResult,
            commits: (log?.stdout ?? "").split(separator: "\n").map(String.init), diff: diffText, diffTruncated: cut,
            check: state.review.check, current: current)
        let arguments = PRDescriber.arguments(config: config, prompt: PRRefresher.prompt(for: input))
        let shown = PRDescriber.displayArguments(arguments)

        guard let claude = ExecutableResolver.resolve(config.claudePath, searchPath: environment["PATH"]) else {
            let why = PRDescribeError.claudeNotFound(config.claudePath).description
            return try await recordProposal(plan, fail: why, argv: shown)
        }
        let runner = GitRunner(executable: claude, environment: config.childEnvironment(from: environment), timeout: timeout)
        let result: GitResult
        do { result = try await runner.run(arguments, in: plan.worktree) } catch GitError.timedOut(_, let seconds) {
            return try await recordProposal(plan, fail: "claude did not answer within \(Int(seconds))s", argv: shown)
        } catch { return try await recordProposal(plan, fail: "claude could not be started", argv: shown) }
        guard result.succeeded else {
            return try await recordProposal(plan, fail: "claude exited with status \(result.status)", argv: shown)
        }

        let proposal: PRRefreshProposal
        do {
            let refresh = try PRRefresher.parse(output: result.stdout, current: current)
            proposal = try Self.proposal(number: pr.number, current: current, refresh: refresh, environment: environment)
        } catch { return try await recordProposal(plan, fail: "\(error)", argv: shown) }

        try await withLog(plan.id) { log in
            try await log.append(
                .prRefreshed,
                data: [
                    "stage": "proposed", "ok": true, "number": .int(proposal.number),
                    "title_changed": .bool(proposal.titleChanged),
                    "sections": .array(proposal.changes.map { .string($0.heading) }),
                    "argv": .array(shown.map { .string($0) }),
                ])
        }
        return PRRefreshResult(proposal: proposal, fallback: nil)
    }

    /// Turns the model's answer into the text that would be published, with credentials and machine paths
    /// removed from what is new.
    static func proposal(
        number: Int, current: PRText, refresh: PRRefresh, environment: [String: String]
    ) throws -> PRRefreshProposal {
        func clean(_ text: String) -> String { withoutCredentials(PRBodyBuilder.scrub(text), environment: environment) }
        let sections = refresh.sections.mapValues(clean)
        let body = try PRBodyRefresher.apply(PRRefresh(title: refresh.title, sections: sections), to: current.body)
        let before = Dictionary(
            PRBodyRefresher.editable(in: current.body).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let changes = sections.sorted { $0.key < $1.key }.compactMap { name, after -> PRRefreshProposal.Change? in
            guard let old = before[name] else { return nil }
            return PRRefreshProposal.Change(heading: old.heading, before: old.content, after: after)
        }
        let title = clean(refresh.title)
        return PRRefreshProposal(
            number: number, current: current, updated: PRText(title: title, body: body),
            titleChanged: title != current.title, changes: changes)
    }

    /// Writes the confirmed proposal with `gh pr edit`. The pull request is read again first: if its text is
    /// no longer what the proposal was made from, someone edited it meanwhile and nothing is written.
    public func applyPRRefresh(
        id: String, plan: ShipPlan, proposal: PRRefreshProposal, gh: GitRunner?, timeout: TimeInterval = ThreadService.prTimeout
    ) async throws {
        guard let gh else { throw ShipError.ghMissing }
        var environment = gh.environment
        environment["GH_REPO"] = nil
        let runner = GitRunner(executable: gh.executable, environment: environment, timeout: timeout)

        let found = try await existingPR(branch: plan.remoteBranch, runner: runner, worktree: plan.worktree)
        guard let found, found.number == proposal.number, found.text == proposal.current else {
            throw ShipError.pullRequestTextChanged
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wb-pr-\(UUID().uuidString).md")
        guard FileManager.default.createFile(
            atPath: file.path, contents: Data(proposal.updated.body.utf8), attributes: [.posixPermissions: 0o600])
        else { throw ShipError.gitFailed("cannot write the PR body to a scratch file") }
        defer { try? FileManager.default.removeItem(at: file) }

        let args = ["pr", "edit", String(proposal.number), "--title=\(proposal.updated.title)", "--body-file", file.path]
        let result: GitResult
        do { result = try await runner.run(args, in: plan.worktree) } catch GitError.timedOut(_, let seconds) {
            throw ShipError.ghEditFailed("`gh pr edit` did not finish in \(Int(seconds))s and was stopped")
        } catch { throw ShipError.ghMissing }
        guard result.succeeded else {
            let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = String(Self.withoutCredentials(text, environment: runner.environment).suffix(2_000))
            throw ShipError.ghEditFailed(shown.isEmpty ? "gh exited \(result.status)" : shown)
        }
        try await withLog(id) { log in
            try await log.append(
                .prRefreshed,
                data: [
                    "stage": "applied", "ok": true, "number": .int(proposal.number),
                    "title_changed": .bool(proposal.titleChanged),
                    "sections": .array(proposal.changes.map { .string($0.heading) }),
                ])
        }
    }

    private func recordProposal(_ plan: ShipPlan, fail reason: String, argv: [String] = []) async throws -> PRRefreshResult {
        let reason = Self.withoutCredentials(PRBodyBuilder.scrub(reason))
        try await withLog(plan.id) { log in
            try await log.append(
                .prRefreshed,
                data: [
                    "stage": "proposed", "ok": false, "reason": .string(reason),
                    "argv": .array(argv.map { .string($0) }),
                ])
        }
        return PRRefreshResult(proposal: nil, fallback: reason)
    }
}
