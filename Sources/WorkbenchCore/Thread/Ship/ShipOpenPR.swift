import Foundation

/// The pull request `shipOpenPR` ended with.
public struct ShipPRResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case created
        /// An open PR for the branch existed already; it was recorded, not duplicated.
        case existing
    }

    public var plan: ShipPlan
    public var url: String
    public var number: Int
    public var outcome: Outcome
}

extension ThreadService {
    public static let prTimeout: TimeInterval = 60

    /// Opens the PR for a pushed thread and records `pr.opened`. An open PR for the branch is looked up
    /// first, so a PR that was created but never recorded (a crash in between) is recorded on the next run
    /// and never duplicated. Writes the event last.
    public func shipOpenPR(
        id: String, gh: GitRunner?, shown: ShipPlan? = nil, description: PRDescription? = nil,
        timeout: TimeInterval = ThreadService.prTimeout
    ) async throws -> ShipPRResult {
        let plan = try await shipPreflight(id: id, gh: gh)
        // The branch is on origin by now, so only what was confirmed about the target must still hold.
        if let shown, !shown.sameTarget(as: plan) { throw ShipError.changedAfterPush }
        switch plan.remote {
        case .upToDate: break
        case .absent: throw ShipError.notPushed("origin has no \(plan.remoteBranch)")
        case .behind(let sha):
            throw ShipError.notPushed("origin is at \(sha.prefix(12)), this thread at \(plan.head.prefix(12))")
        }
        guard let gh else { throw ShipError.ghMissing }
        // `GH_REPO` would point lookup and creation somewhere other than the origin that was just verified.
        var environment = gh.environment
        environment["GH_REPO"] = nil
        let runner = GitRunner(executable: gh.executable, environment: environment, timeout: timeout)

        let found = try await existingPR(branch: plan.remoteBranch, runner: runner, worktree: plan.worktree)
        if plan.updatesExistingBranch && found == nil { throw ShipError.noPullRequest(plan.remoteBranch) }
        let outcome: ShipPRResult.Outcome
        let pr: FoundPR
        if let found {
            outcome = .existing
            pr = found
        } else {
            outcome = .created
            pr = try await createPR(plan: plan, runner: runner, description: description)
        }
        let (url, number, base) = (pr.url, pr.number, pr.base ?? plan.base)
        let head = pr.head ?? plan.head

        try await withLog(id) { log in
            try await log.append(
                .prOpened,
                data: [
                    "url": .string(url), "number": .int(number), "branch": .string(plan.remoteBranch),
                    "base": .string(base), "head_sha": .string(head),
                ])
        }
        return ShipPRResult(plan: plan, url: url, number: number, outcome: outcome)
    }

    // MARK: Lookup

    private struct FoundPR {
        var url: String
        var number: Int
        var base: String?
        /// The PR's own head commit, when `gh` reported one.
        var head: String?
    }

    private func existingPR(branch: String, runner: GitRunner, worktree: URL) async throws -> FoundPR? {
        let args = [
            "pr", "list", "--head", branch, "--state", "open", "--limit", "10",
            "--json", "number,url,headRefName,baseRefName,headRefOid",
        ]
        let result = try await ghRun(args, runner: runner, worktree: worktree)
        guard result.succeeded else { throw ShipError.ghFailed(Self.shown(result, environment: runner.environment)) }
        guard let data = result.stdout.data(using: .utf8),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw ShipError.ghFailed("`gh pr list` did not answer with JSON") }
        for item in list where item["headRefName"] as? String == branch {
            // A record for our branch that cannot be trusted is an error, not "no PR": creating a second
            // one on top of it is the thing this lookup exists to prevent.
            guard let url = item["url"] as? String, let parsed = Self.pullRequest(from: url),
                (item["number"] as? Int) == parsed.number
            else { throw ShipError.ghFailed("`gh pr list` returned a pull request for \(branch) that is not usable") }
            let base = (item["baseRefName"] as? String).flatMap { SafeNames.isBranchName($0) ? $0 : nil }
            let head = (item["headRefOid"] as? String).flatMap {
                $0.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil ? $0 : nil
            }
            return FoundPR(url: parsed.url, number: parsed.number, base: base, head: head)
        }
        return nil
    }

    // MARK: Create

    /// The title and body `ship` gives the pull request, built the same way for the preview the person
    /// confirms and for the PR itself.
    public func prBody(plan: ShipPlan, description: PRDescription?, environment: [String: String]) async throws -> PRBody {
        let events = (try? EventLogReader.read(at: project.eventsURL(plan.id)))?.events ?? []
        let goal: Goal
        do {
            goal = try GoalFile.parse(String(contentsOf: project.goalURL(plan.id), encoding: .utf8)).goal
        } catch { throw ShipError.goalUnreadable("\(error)") }

        // The template is the committed one at the base, not whatever the worktree has now.
        var template: String?
        if let commit = events.last(where: { $0.kind == .worktreeCreated })?.data["base_commit"]?.stringValue,
            commit.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil {
            let reader = ProjectInstructions.BlobReader(git: git, repo: project.root, commit: commit)
            for path in [".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md"] {
                if let text = await reader.read(path) {
                    // The reader cuts at its limit; a template cut short would drop sections without a word.
                    guard text.utf8.count < ProjectInstructions.blobReadLimit else {
                        throw ShipError.gitFailed("\(path) is larger than 64 KiB; shorten it so the whole template is used.")
                    }
                    template = text
                    break
                }
                // Not read, but there: too large for the reader, so it is not silently treated as absent.
                let present = try? await git.run(["cat-file", "-e", "\(commit):\(path)"], in: project.root)
                if present?.succeeded == true {
                    throw ShipError.gitFailed("\(path) cannot be read (larger than 1 MiB or not a regular file)")
                }
            }
        }
        let state = ThreadState.derive(from: events, id: plan.id)
        var body = PRBodyBuilder.build(
            goal: goal, check: state.review.check, template: template, lastTurn: state.lastTurn,
            description: description)
        // What is published must not carry a credential that was pasted into the goal or the template.
        body.title = Self.withoutCredentials(body.title, environment: environment)
        body.body = Self.withoutCredentials(body.body, environment: environment)
        return body
    }

    private func createPR(plan: ShipPlan, runner: GitRunner, description: PRDescription?) async throws -> FoundPR {
        let body = try await prBody(plan: plan, description: description, environment: runner.environment)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wb-pr-\(UUID().uuidString).md")
        guard FileManager.default.createFile(
            atPath: file.path, contents: Data(body.body.utf8), attributes: [.posixPermissions: 0o600])
        else { throw ShipError.gitFailed("cannot write the PR body to a scratch file") }
        defer { try? FileManager.default.removeItem(at: file) }

        let args = [
            "pr", "create", "--base", plan.base, "--head", plan.branch, "--title=\(body.title)",
            "--body-file", file.path,
        ]
        let result = try await ghRun(args, runner: runner, worktree: plan.worktree)
        guard result.succeeded else { throw ShipError.ghFailed(Self.shown(result, environment: runner.environment)) }
        let last = result.stdout.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let parsed = Self.pullRequest(from: last) else {
            throw ShipError.ghFailed("`gh` printed no pull request URL, so it was not recorded")
        }
        return FoundPR(url: parsed.url, number: parsed.number, base: nil, head: nil)
    }

    private func ghRun(_ args: [String], runner: GitRunner, worktree: URL) async throws -> GitResult {
        do { return try await runner.run(args, in: worktree) } catch GitError.timedOut(_, let seconds) {
            throw ShipError.gitFailed(
                "`gh \(args.prefix(2).joined(separator: " "))` did not finish in \(Int(seconds))s and was stopped. "
                    + "Nothing was recorded; run it again.")
        } catch { throw ShipError.ghMissing }
    }

    private static func shown(_ result: GitResult, environment: [String: String]) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = String(withoutCredentials(text, environment: environment).suffix(2_000))
        return clean.isEmpty ? "gh exited \(result.status)" : clean
    }

    /// A plain `https://host/owner/repo/pull/<n>`: no user info, no query, no fragment, nothing after.
    static func pullRequest(from text: String) -> (url: String, number: Int)? {
        guard let parts = URLComponents(string: text), parts.scheme == "https", parts.user == nil,
            parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
            let host = parts.host, !host.isEmpty
        else { return nil }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 5, segments[0].isEmpty, segments[3] == "pull", !segments[1].isEmpty,
            !segments[2].isEmpty, let number = Int(segments[4]), number > 0, String(number) == segments[4]
        else { return nil }
        return (text, number)
    }
}
