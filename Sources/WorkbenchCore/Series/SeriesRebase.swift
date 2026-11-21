import Foundation

/// What `series rebase` did for one stacked step.
public enum SeriesRebaseOutcome: Sendable, Equatable {
    /// The step's branch was replayed onto the base and pushed, and its pull request now targets the base.
    case rebased(pullRequest: Int, base: String)
    /// Nothing to do: the pull request already targets the base and its branch no longer carries the parent's commits.
    case alreadyDone
    /// The parent's pull request is not merged yet (or the step has no thread or pull request yet).
    case waiting(String)
    /// The replay hit a conflict; nothing was pushed or changed. The files are the ones in conflict.
    case conflict(files: [String])
    case failed(String)
}

public struct SeriesRebaseStep: Sendable, Equatable {
    public var step: Int
    public var outcome: SeriesRebaseOutcome
}

/// After a parent's pull request is merged, retargets the step stacked on it to the base branch and replays its own commits there
/// (`git rebase --onto origin/<base> <where the step was cut> <its branch>`, then `--force-with-lease`): a squash merge gives the
/// parent a new commit, so a plain rebase would replay the parent's commits again. The work happens in a throwaway worktree; a
/// conflict aborts it and nothing is pushed. Never merges, never resolves a conflict.
public struct SeriesRebaser: Sendable {
    public let library: SeriesLibrary
    public var git: GitRunner
    public var gh: GitRunner?
    public var say: @Sendable (String) -> Void = { _ in }

    public init(library: SeriesLibrary, git: GitRunner, gh: GitRunner?) {
        self.library = library
        self.git = git
        self.gh = gh
    }

    public func run(_ name: String) async throws -> [SeriesRebaseStep] {
        let loaded = try library.load(name)
        let records = SeriesStepLog(project: library.project, series: name).read()
        var results: [SeriesRebaseStep] = []
        for step in loaded.definition.steps {
            guard case .after(let parentNumber) = step.base else { continue }
            guard let record = records[step.number], let parent = records[parentNumber], let root = loaded.projects[step.number]
            else {
                let outcome = SeriesRebaseOutcome.waiting("the step or its parent has no thread yet")
                results.append(SeriesRebaseStep(step: step.number, outcome: outcome))
                continue
            }
            let outcome = await rebase(thread: record.thread, parent: parent.thread, root: root)
            results.append(SeriesRebaseStep(step: step.number, outcome: outcome))
        }
        return results
    }

    // MARK: One step

    private struct LivePR {
        var number: Int
        var state: PRState
        var base: String
        var head: String
    }

    private func rebase(thread: String, parent: String, root: URL) async -> SeriesRebaseOutcome {
        let project = Project(root: root)
        let store = ThreadStore(project: project)
        guard let childPR = store.state(of: thread).pullRequest?.number,
            let parentPR = store.state(of: parent).pullRequest?.number
        else { return .waiting("the step or its parent has not opened a pull request") }
        guard let gh else { return .failed("`gh` was not found") }
        var environment = gh.environment
        environment["GH_REPO"] = nil
        let reader = GitRunner(executable: gh.executable, environment: environment, timeout: ThreadService.prTimeout)

        let parentLive: LivePR
        let childLive: LivePR
        do {
            parentLive = try await view(parentPR, reader: reader, root: root)
            childLive = try await view(childPR, reader: reader, root: root)
        } catch { return .failed("\(error)") }
        guard parentLive.state == .merged else { return .waiting("the parent's pull request #\(parentPR) is not merged yet") }
        guard childLive.state == .open else {
            return .failed("the pull request #\(childPR) is \(childLive.state.rawValue), not open")
        }

        // Where the parent was merged: the base its own pull request targeted.
        let base = parentLive.base
        let branch = Self.branch(project: project, thread: thread)
        guard SafeNames.isBranchName(base), SafeNames.isBranchName(branch) else {
            return .failed("an unsafe branch name: \(base), \(branch)")
        }
        guard let cutAt = Self.cutPoint(project: project, thread: thread) else {
            return .failed("the step's log has no commit it was cut from (worktree.created base_commit)")
        }

        do { try await fetch(base: base, branch: branch, root: root) } catch { return .failed("\(error)") }
        // Done already: the branch no longer carries the commit it was cut from (the parent's old tip), or that commit is in the base.
        let carries = await succeeded(["merge-base", "--is-ancestor", cutAt, "refs/remotes/origin/\(branch)"], root)
        let inBase = await succeeded(["merge-base", "--is-ancestor", cutAt, "refs/remotes/origin/\(base)"], root)
        let needsReplay = carries && !inBase
        if !needsReplay, childLive.base == base { return .alreadyDone }

        if needsReplay {
            switch await replay(branch: branch, cutAt: cutAt, base: base, oldTip: childLive.head, root: root) {
            case .conflict(let files): return .conflict(files: files)
            case .failed(let why): return .failed(why)
            case .pushed: break
            }
        }
        if childLive.base != base {
            let edited = try? await reader.run(["pr", "edit", String(childPR), "--base", base], in: root)
            guard edited?.succeeded == true else {
                return .failed("the branch was rebased, but `gh pr edit --base \(base)` failed: run `series rebase` again")
            }
        }
        return .rebased(pullRequest: childPR, base: base)
    }

    private enum Replay {
        case pushed
        case conflict([String])
        case failed(String)
    }

    /// Replays the step's own commits (those after `cutAt`) onto the base in a throwaway worktree and pushes the result with a lease
    /// on the tip the pull request had. The worktree is removed on every path.
    private func replay(branch: String, cutAt: String, base: String, oldTip: String, root: URL) async -> Replay {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("series-rebase-\(UUID().uuidString)")
        let added = try? await git.run(["worktree", "add", "--detach", scratch.path, "refs/remotes/origin/\(branch)"], in: root)
        guard added?.succeeded == true else { return .failed("could not make a worktree to rebase in") }
        let outcome = await replayInside(scratch, branch: branch, cutAt: cutAt, base: base, oldTip: oldTip)
        _ = try? await git.run(["worktree", "remove", "--force", scratch.path], in: root)
        return outcome
    }

    private func replayInside(_ scratch: URL, branch: String, cutAt: String, base: String, oldTip: String) async -> Replay {
        let rebased = try? await git.run(["rebase", "--onto", "refs/remotes/origin/\(base)", cutAt], in: scratch)
        guard rebased?.succeeded == true else {
            let listed = try? await git.run(["diff", "--name-only", "--diff-filter=U"], in: scratch)
            let files = (listed?.stdout ?? "").split(separator: "\n").map(String.init)
            _ = try? await git.run(["rebase", "--abort"], in: scratch)
            if files.isEmpty { return .failed("git rebase failed: \(Self.lastLine(rebased?.stderr))") }
            return .conflict(files)
        }
        let lease = "--force-with-lease=refs/heads/\(branch):\(oldTip)"
        let pushed = try? await git.run(["push", lease, "origin", "HEAD:refs/heads/\(branch)"], in: scratch)
        guard pushed?.succeeded == true else {
            return .failed("the push was refused (the branch moved, or origin said no): \(Self.lastLine(pushed?.stderr))")
        }
        return .pushed
    }

    private static func lastLine(_ text: String?) -> String { text?.split(separator: "\n").last.map(String.init) ?? "no output" }

    // MARK: Reading

    private func view(_ number: Int, reader: GitRunner, root: URL) async throws -> LivePR {
        let result = try await reader.run(["pr", "view", String(number), "--json", "state,baseRefName,headRefOid"], in: root)
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = json["state"] as? String, let state = PRState(rawValue: raw.lowercased()),
            let base = json["baseRefName"] as? String, let head = json["headRefOid"] as? String,
            SafeNames.isCommitSHA(head)
        else { throw SeriesError.writeFailed("`gh pr view \(number)` did not answer with a state, a base and a head") }
        return LivePR(number: number, state: state, base: base, head: head)
    }

    private func fetch(base: String, branch: String, root: URL) async throws {
        let refspecs = [
            "+refs/heads/\(base):refs/remotes/origin/\(base)", "+refs/heads/\(branch):refs/remotes/origin/\(branch)",
        ]
        let result = try await git.run(["fetch", "--no-tags", "--quiet", "origin"] + refspecs, in: root)
        guard result.succeeded else {
            throw SeriesError.writeFailed("could not fetch \(base) and \(branch) from origin: \(Self.lastLine(result.stderr))")
        }
    }

    private func succeeded(_ arguments: [String], _ root: URL) async -> Bool {
        (try? await git.run(arguments, in: root))?.succeeded == true
    }

    /// The branch a step's pull request is on: `push_to` when its goal continued one, else `workbench/<thread>`.
    static func branch(project: Project, thread: String) -> String {
        let goal = (try? String(contentsOf: project.goalURL(thread), encoding: .utf8)).flatMap { try? GoalFile.parse($0).goal }
        return goal?.pushTo ?? WorktreeManager.branch(for: thread)
    }

    /// The commit the step's worktree was cut from, as `worktree.created` recorded it: the parent's tip then.
    static func cutPoint(project: Project, thread: String) -> String? {
        let events = (try? EventLogReader.read(at: project.eventsURL(thread)))?.events ?? []
        guard let sha = events.last(where: { $0.kind == .worktreeCreated })?.data["base_commit"]?.stringValue,
            SafeNames.isCommitSHA(sha)
        else { return nil }
        return sha
    }
}
