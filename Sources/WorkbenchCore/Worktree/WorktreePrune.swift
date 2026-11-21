import Foundation

/// What `workbench prune` found for one worktree of the repository, and what it did (or, in a dry run, would do).
public struct PruneEntry: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The main checkout: listed, never touched.
        case primary
        /// A worktree git lists.
        case registered
        /// A directory under `.workbench/worktrees/` that git does not list.
        case unregistered
    }

    public enum Verdict: Sendable, Equatable {
        case removable(String)
        case kept(String)
    }

    /// What happened to the worktree (or the directory).
    public enum Outcome: Sendable, Equatable {
        case untouched
        case wouldRemove
        case removed
        case failed(String)
    }

    /// What happened to its local branch.
    public enum BranchOutcome: Sendable, Equatable {
        case none
        case wouldRemove
        case removed
        case kept(String)
    }

    public var path: String
    public var kind: Kind
    /// The short branch name; nil for a detached HEAD or a directory git does not know.
    public var branch: String?
    public var head: String?
    public var verdict: Verdict
    /// The verdict depends on GitHub and GitHub could not be asked.
    public var lookupFailed = false
    public var outcome: Outcome = .untouched
    public var branchOutcome: BranchOutcome = .none
    /// The thread's log could not record what was removed (`worktree.removed` or `branch.removed`), and why.
    public var recordFailed: String?

    public var isRemovable: Bool { if case .removable = verdict { true } else { false } }
}

public struct PruneReport: Sendable, Equatable {
    public var entries: [PruneEntry]
    public var dryRun: Bool
    public var defaultBranch: String

    public var lookupFailed: Bool { entries.contains(where: \.lookupFailed) }
    public var removalFailed: Bool {
        entries.contains { entry in
            if case .failed = entry.outcome { return true }
            return false
        }
    }
    public var recordFailed: Bool { entries.contains { $0.recordFailed != nil } }
}

public enum PruneError: Error, Equatable, Sendable, CustomStringConvertible {
    case cannotList(String)

    public var description: String {
        switch self {
        case .cannotList(let why): "git could not list the worktrees: \(why)"
        }
    }
}

/// One pull request of a branch, as `gh pr list --head` gives it.
struct BranchPR: Sendable, Equatable {
    var number: Int
    var state: PRState
    var head: String
}

extension ThreadService {
    /// Lists every worktree of the repository and says which can be removed; unless `dryRun`, removes those (with
    /// `git worktree remove`, never forced) and the local branches that were removable with them. Directories under
    /// `.workbench/worktrees/` that git does not list are removed only with `unregistered`, and never when a thread
    /// names them. GitHub is asked about every branch, also one already on the default branch (an open pull request, or a
    /// closed one without `includeClosed`, keeps it); when GitHub cannot answer, a branch on the default branch is still
    /// decided by git and the others are kept.
    public func prune(
        gh: GitRunner?, includeClosed: Bool, unregistered: Bool, dryRun: Bool
    ) async throws -> PruneReport {
        let records = try await listWorktrees()
        let defaultBranch = await defaultBase()
        let defaultRefs = await existingRefs(["refs/remotes/origin/\(defaultBranch)", "refs/heads/\(defaultBranch)"])
        var lookups = PRLookups(gh: gh, root: project.root)

        var entries: [PruneEntry] = []
        var primaryBranch: String?
        for (index, record) in records.enumerated() {
            if index == 0 || record.bare {
                primaryBranch = primaryBranch ?? record.branch
                entries.append(
                    PruneEntry(
                        path: record.path, kind: .primary, branch: record.branch, head: record.head,
                        verdict: .kept("the primary checkout")))
                continue
            }
            entries.append(
                await judge(record, defaultBranch: defaultBranch, defaultRefs: defaultRefs, includeClosed: includeClosed,
                    lookups: &lookups))
        }
        entries += unregisteredEntries(registered: records.map(\.path), allowed: unregistered)

        if !dryRun {
            for index in entries.indices where entries[index].isRemovable {
                await remove(&entries[index], keepBranches: [defaultBranch, primaryBranch].compactMap { $0 })
            }
        } else {
            for index in entries.indices where entries[index].isRemovable {
                entries[index].outcome = .wouldRemove
                if let branch = entries[index].branch {
                    entries[index].branchOutcome =
                        [defaultBranch, primaryBranch].contains(branch) ? .kept("the default branch") : .wouldRemove
                }
            }
        }
        return PruneReport(entries: entries, dryRun: dryRun, defaultBranch: defaultBranch)
    }

    // MARK: Listing

    struct WorktreeRecord: Equatable {
        var path: String
        var head: String?
        /// Short name, `refs/heads/` dropped; nil when detached.
        var branch: String?
        /// The full ref as git printed it, for a branch that is not under `refs/heads/`.
        var rawBranch: String?
        var bare = false
        var locked = false
        var prunable = false
    }

    /// How many branches holding a detached commit are asked about before the rest are said to be unasked.
    static let detachedLookupLimit = 100

    /// `git worktree list --porcelain -z`, where a path is printed as it is. A git older than 2.36 has no `-z`: then the
    /// newline form is read, where git C-quotes a path with special characters; such a path starts with `"`, fails
    /// `isSafeWorktreePath` and is kept, never unquoted by hand.
    private func listWorktrees() async throws -> [WorktreeRecord] {
        let nul = try? await git.run(["worktree", "list", "--porcelain", "-z"], in: project.root)
        if let nul, nul.succeeded, !nul.outputTruncated { return Self.parseWorktreeList(nul.stdout, separator: "\0") }
        let listed = try? await git.run(["worktree", "list", "--porcelain"], in: project.root)
        guard let listed, listed.succeeded, !listed.outputTruncated else {
            let why = (listed ?? nul)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PruneError.cannotList(why.map { $0.isEmpty ? "git failed" : $0 } ?? "git did not run")
        }
        return Self.parseWorktreeList(listed.stdout, separator: "\n")
    }

    /// `git worktree list --porcelain`: one field per line (per NUL with `-z`), records separated by an empty field, the
    /// first one the main checkout.
    static func parseWorktreeList(_ text: String, separator: Character = "\n") -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []
        var current: WorktreeRecord?
        for line in text.split(separator: separator, omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("worktree ") {
                if let current { records.append(current) }
                current = WorktreeRecord(path: String(line.dropFirst("worktree ".count)))
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.rawBranch = ref
                if ref.hasPrefix("refs/heads/") { current?.branch = String(ref.dropFirst("refs/heads/".count)) }
            } else if line == "bare" {
                current?.bare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.prunable = true
            }
        }
        if let current { records.append(current) }
        return records
    }

    /// A path git printed that is safe to hand back to git: absolute, no `.` or `..` component, no control character.
    static func isSafeWorktreePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count < 4096,
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    // MARK: Judging

    private func judge(
        _ record: WorktreeRecord, defaultBranch: String, defaultRefs: [String], includeClosed: Bool,
        lookups: inout PRLookups
    ) async -> PruneEntry {
        var entry = PruneEntry(
            path: record.path, kind: .registered, branch: record.branch, head: record.head, verdict: .kept(""))
        func kept(_ why: String) -> PruneEntry {
            entry.verdict = .kept(why)
            return entry
        }
        guard Self.isSafeWorktreePath(record.path) else { return kept("its path is not one Workbench passes to git") }
        if record.prunable { return kept("its directory is gone; `git worktree prune` forgets it") }
        if record.locked { return kept("locked") }
        if let why = threadHold(at: URL(fileURLWithPath: record.path)) { return kept(why) }
        if record.rawBranch != nil, record.branch == nil { return kept("its branch is not a local branch") }
        if let branch = record.branch, !SafeNames.isBranchName(branch) {
            return kept("its branch name is not one Workbench passes to git")
        }
        guard let head = record.head, SafeNames.isCommitSHA(head) else { return kept("git did not say which commit it is at") }

        let status = try? await git.run(
            ["status", "--porcelain", "--untracked-files=normal"], in: URL(fileURLWithPath: record.path))
        guard let status, status.succeeded else { return kept("git could not read its status") }
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return kept("uncommitted changes") }

        let onDefault = await isAncestor(head, ofAny: defaultRefs).map(Self.shortRef)
        guard let branch = record.branch else {
            if let onDefault {
                entry.verdict = .removable("detached at a commit on \(onDefault)")
                return entry
            }
            return await judgeDetached(head: head, entry: entry, lookups: &lookups)
        }
        // A branch already on the default branch is still asked about: an open pull request, or a closed one without
        // --closed, keeps it. Only when GitHub cannot answer does git's answer decide alone.
        switch await lookups.prs(of: branch) {
        case .failure(let why):
            if let onDefault {
                entry.verdict = .removable("merged into \(onDefault) (GitHub could not be asked, so git decided: \(why.why))")
                return entry
            }
            entry.lookupFailed = true
            return kept("GitHub could not be asked (\(why.why))")
        case .success(let prs):
            return await decide(prs: prs, head: head, onDefault: onDefault, entry: entry, includeClosed: includeClosed)
        }
    }

    /// The verdict from a branch's pull requests: an open one keeps, merged (with the tip in its head) removes, a closed one
    /// removes only with `includeClosed`; with none of those, a tip on the default branch (`onDefault`) removes.
    private func decide(
        prs: [BranchPR], head: String, onDefault: String?, entry: PruneEntry, includeClosed: Bool
    ) async -> PruneEntry {
        var entry = entry
        var covering: [BranchPR] = []
        for pr in prs where await contains(pr.head, head) { covering.append(pr) }
        let closed = covering.first { $0.state == .closed } ?? (onDefault == nil ? nil : prs.first { $0.state == .closed })
        if let open = prs.first(where: { $0.state == .open }) {
            entry.verdict = .kept("pull request #\(open.number) is open")
        } else if let merged = covering.first(where: { $0.state == .merged }) {
            entry.verdict = .removable("pull request #\(merged.number) is merged")
        } else if let closed {
            entry.verdict =
                includeClosed
                ? .removable("pull request #\(closed.number) was closed without merging")
                : .kept("pull request #\(closed.number) was closed without merging; --closed removes it")
        } else if let onDefault {
            entry.verdict = .removable("merged into \(onDefault)")
        } else if !prs.isEmpty {
            entry.verdict = .kept("it has commits after its pull request")
        } else {
            entry.verdict = .kept("no pull request, and commits not on the default branch")
        }
        return entry
    }

    private func judgeDetached(head: String, entry: PruneEntry, lookups: inout PRLookups) async -> PruneEntry {
        var entry = entry
        let result = try? await git.run(
            ["for-each-ref", "--contains", head, "--format=%(refname)", "refs/heads", "refs/remotes/origin"],
            in: project.root)
        var names: [String] = []
        for ref in (result?.stdout ?? "").split(separator: "\n").map(String.init) {
            guard let prefix = ["refs/heads/", "refs/remotes/origin/"].first(where: ref.hasPrefix) else { continue }
            let name = String(ref.dropFirst(prefix.count))
            if name != "HEAD", SafeNames.isBranchName(name), !names.contains(name) { names.append(name) }
        }
        guard result?.succeeded == true, result?.outputTruncated == false else {
            entry.verdict = .kept("detached; git could not say which branches hold its commit")
            return entry
        }
        // Local branches come first in git's order (refs/heads sorts before refs/remotes). Every name is asked about, up to
        // a bound: one past it is said, never silently skipped.
        var failure: String?
        let limit = Self.detachedLookupLimit
        for name in names.prefix(limit) {
            switch await lookups.prs(of: name) {
            case .failure(let why): failure = failure ?? why.why
            case .success(let prs):
                for pr in prs where pr.state == .merged {
                    if await contains(pr.head, head) {
                        entry.verdict = .removable("detached at a commit on \(name), whose pull request #\(pr.number) is merged")
                        return entry
                    }
                }
            }
        }
        if let failure {
            entry.lookupFailed = true
            entry.verdict = .kept("detached; GitHub could not be asked (\(failure))")
        } else if names.count > limit {
            entry.verdict = .kept(
                "detached at a commit on \(names.count) branches; the first \(limit) have no merged pull request "
                    + "holding it, the rest were not asked")
        } else {
            entry.verdict = .kept("detached at a commit not on the default branch or a merged pull request")
        }
        return entry
    }

    /// Why the thread whose worktree this is must keep it, or nil when no thread does.
    private func threadHold(at path: URL) -> String? {
        guard let id = threadID(owning: path) else { return nil }
        let store = ThreadStore(project: project)
        let contents = try? EventLogReader.read(at: project.eventsURL(id))
        if contents?.openTurn != nil || contents?.openCheck != nil || contents?.openVerifier != nil
            || store.runnerPID(id: id) != nil || store.holdsHerdrSession(id: id) {
            return "thread \(id) has an active turn"
        }
        if store.state(from: contents?.events ?? [], id: id).decision == nil { return "thread \(id) has not ended" }
        return nil
    }

    /// The thread that names a directory: `.workbench/worktrees/<id>` with a `threads/<id>` folder.
    private func threadID(owning path: URL) -> String? {
        let parent = path.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path
        let worktrees = project.root.appendingPathComponent(".workbench/worktrees").resolvingSymlinksInPath()
            .standardizedFileURL.path
        let name = path.lastPathComponent
        guard parent == worktrees, SafeNames.isThreadID(name),
            FileManager.default.fileExists(atPath: project.threadDirectory(name).path)
        else { return nil }
        return name
    }

    private func unregisteredEntries(registered: [String], allowed: Bool) -> [PruneEntry] {
        let folder = project.root.appendingPathComponent(".workbench/worktrees")
        let threads = Set(ThreadStore(project: project).threadIDs())
        let listingComplete = registered.allSatisfy(Self.isSafeWorktreePath)
        let known = Set(registered.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var entries: [PruneEntry] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard WorktreeManager.type(of: url) == .typeDirectory, !known.contains(resolved) else { continue }
            var entry = PruneEntry(path: url.path, kind: .unregistered, branch: nil, head: nil, verdict: .kept(""))
            // A directory holding a registered worktree (`group/live`) is never removed with it: that one is judged itself.
            if let inner = known.first(where: { $0.hasPrefix(resolved + "/") }) {
                entry.verdict = .kept("unregistered, but it holds the worktree at \(inner)")
                entries.append(entry)
                continue
            }
            // A thread names its worktree `.workbench/worktrees/<id>`. The name is only compared, never put in a git
            // argument, and the directory is removed by path without following links (only a real directory is listed).
            if threads.contains(name)
                || FileManager.default.fileExists(atPath: project.threadsDirectory.appendingPathComponent(name).path) {
                entry.verdict = .kept("unregistered, but thread \(name) names it")
            } else if !listingComplete {
                entry.verdict = .kept("unregistered, but git listed a worktree path that could not be read; it may be this one")
            } else if !allowed {
                entry.verdict = .kept("unregistered; --unregistered removes it")
            } else {
                entry.verdict = .removable("unregistered: git does not list it and no thread names it")
            }
            entries.append(entry)
        }
        return entries
    }

    // MARK: Git questions

    private func existingRefs(_ refs: [String]) async -> [String] {
        var found: [String] = []
        for ref in refs {
            let probe = try? await git.run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: project.root)
            if probe?.succeeded == true { found.append(ref) }
        }
        return found
    }

    /// The first of `refs` that `commit` is an ancestor of, or nil.
    private func isAncestor(_ commit: String, ofAny refs: [String]) async -> String? {
        for ref in refs {
            let result = try? await git.run(["merge-base", "--is-ancestor", commit, ref], in: project.root)
            if result?.succeeded == true { return ref }
        }
        return nil
    }

    /// Whether `tip` is `prHead` or an ancestor of it (a PR head git has not fetched counts only when it is the same commit).
    private func contains(_ prHead: String, _ tip: String) async -> Bool {
        if prHead == tip { return true }
        guard SafeNames.isCommitSHA(prHead) else { return false }
        let result = try? await git.run(["merge-base", "--is-ancestor", tip, prHead], in: project.root)
        return result?.succeeded == true
    }

    private static func shortRef(_ ref: String) -> String {
        if ref.hasPrefix("refs/remotes/") { return String(ref.dropFirst("refs/remotes/".count)) }
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        return ref
    }

    // MARK: Removing

    private func remove(_ entry: inout PruneEntry, keepBranches: [String]) async {
        let url = URL(fileURLWithPath: entry.path)
        if entry.kind == .unregistered {
            do {
                try FileManager.default.removeItem(at: url)
                entry.outcome = .removed
            } catch {
                entry.outcome = .failed(error.localizedDescription)
            }
            return
        }
        guard Self.isSafeWorktreePath(entry.path) else { entry.outcome = .failed("unsafe path"); return }
        // The GitHub lookups took time: look again right before removing, and keep a worktree that changed meanwhile.
        if let why = await changed(entry) {
            entry.verdict = .kept("it changed since it was looked at (\(why)); run prune again")
            return
        }
        let thread = threadID(owning: url)
        let result = try? await git.run(["worktree", "remove", entry.path], in: project.root)
        guard let result, result.succeeded else {
            let why = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            entry.outcome = .failed(why.isEmpty ? "git worktree remove failed" : String(why.suffix(300)))
            entry.branchOutcome = entry.branch == nil ? .none : .kept("its worktree is still there")
            return
        }
        entry.outcome = .removed
        if let thread {
            do {
                let data: JSONValue = ["reason": "prune", "path": .string(entry.path)]
                try await withLog(thread) { _ = try await $0.append(.worktreeRemoved, data: data) }
            } catch { entry.recordFailed = "worktree.removed was not written to thread \(thread)'s log (\(error))" }
        }
        guard let branch = entry.branch, let head = entry.head else { return }
        if keepBranches.contains(branch) {
            entry.branchOutcome = .kept("the default branch")
            return
        }
        if let why = await deleteLocalBranch(branch, at: head) {
            entry.branchOutcome = .kept(why)
            return
        }
        entry.branchOutcome = .removed
        if let thread, branch == WorktreeManager.branch(for: thread) {
            do {
                let data: JSONValue = ["reason": "prune", "head_sha": .string(head)]
                try await withLog(thread) { _ = try await $0.append(.branchRemoved, data: data) }
            } catch {
                let missing = "branch.removed was not written to thread \(thread)'s log (\(error))"
                entry.recordFailed = entry.recordFailed.map { $0 + "; " + missing } ?? missing
            }
        }
    }

    /// What changed about a registered worktree since it was judged (its commit, branch, lock or thread), or nil.
    private func changed(_ entry: PruneEntry) async -> String? {
        guard let records = try? await listWorktrees() else { return "git could not list the worktrees" }
        guard let now = records.first(where: { $0.path == entry.path }) else { return "git no longer lists it" }
        if now.head != entry.head || now.branch != entry.branch { return "its commit or branch moved" }
        return now.locked ? "it is locked" : threadHold(at: URL(fileURLWithPath: entry.path))
    }

    /// Deletes `refs/heads/<branch>` only if it still points at `sha` and no worktree has it checked out.
    private func deleteLocalBranch(_ branch: String, at sha: String) async -> String? {
        guard SafeNames.isBranchName(branch), SafeNames.isCommitSHA(sha) else { return "not a branch name or commit" }
        let ref = "refs/heads/" + branch
        let listed = try? await git.run(["worktree", "list", "--porcelain"], in: project.root)
        guard let listed, listed.succeeded else { return "git could not list its worktrees" }
        if listed.stdout.split(separator: "\n").contains(where: { $0 == "branch \(ref)" }) {
            return "it is checked out in another worktree"
        }
        let result = try? await git.run(["update-ref", "-d", ref, sha], in: project.root)
        guard result?.succeeded == true else { return "it moved since it was looked at, or git refused" }
        return nil
    }
}

/// Asks GitHub about each branch once per run.
struct PRLookups {
    let gh: GitRunner?
    let root: URL
    private var answers: [String: Result<[BranchPR], CleanLookupError>] = [:]

    init(gh: GitRunner?, root: URL) {
        self.gh = gh
        self.root = root
    }

    mutating func prs(of branch: String) async -> Result<[BranchPR], CleanLookupError> {
        if let known = answers[branch] { return known }
        let answer = await ask(branch)
        answers[branch] = answer
        return answer
    }

    /// `gh pr list --head <branch> --state all --json number,state,headRefOid`, from the project root.
    private func ask(_ branch: String) async -> Result<[BranchPR], CleanLookupError> {
        guard let gh else { return .failure(CleanLookupError("`gh` was not found")) }
        guard SafeNames.isBranchName(branch) else { return .failure(CleanLookupError("not a branch name")) }
        var environment = gh.environment
        environment["GH_REPO"] = nil
        let runner = GitRunner(executable: gh.executable, environment: environment, timeout: ThreadService.prTimeout)
        let result: GitResult
        do {
            result = try await runner.run(
                ["pr", "list", "--head", branch, "--state", "all", "--limit", "30", "--json", "number,state,headRefOid"],
                in: root)
        } catch GitError.timedOut(_, let seconds) {
            return .failure(CleanLookupError("`gh pr list` did not answer in \(Int(seconds))s"))
        } catch { return .failure(CleanLookupError("`gh` could not be run")) }
        guard result.succeeded else {
            let why = ThreadService.withoutCredentials(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), environment: environment)
            return .failure(CleanLookupError(why.isEmpty ? "`gh pr list` exited \(result.status)" : String(why.suffix(300))))
        }
        guard let data = result.stdout.data(using: .utf8),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return .failure(CleanLookupError("`gh pr list` did not answer with a list")) }
        var prs: [BranchPR] = []
        for item in list {
            guard let number = (item["number"] as? NSNumber)?.intValue,
                let raw = item["state"] as? String, let state = PRState(rawValue: raw.lowercased()),
                let head = item["headRefOid"] as? String
            else { return .failure(CleanLookupError("`gh pr list` answered with a pull request it did not describe")) }
            prs.append(BranchPR(number: number, state: state, head: head))
        }
        return .success(prs)
    }
}

extension PruneReport {
    /// One line per worktree, and one per thing done to it, ready to print.
    public func render() -> [String] {
        var lines: [String] = []
        for entry in entries {
            let name = entry.branch.map { " (\($0))" } ?? (entry.kind == .unregistered ? "" : " (detached)")
            switch entry.verdict {
            case .kept(let why):
                lines.append("kept       \(entry.path)\(name): \(why)")
            case .removable(let why):
                lines.append("removable  \(entry.path)\(name): \(why)")
            }
            switch entry.outcome {
            case .untouched: break
            case .wouldRemove: lines.append("  worktree: would remove")
            case .removed: lines.append("  worktree: removed")
            case .failed(let why): lines.append("  worktree: not removed (\(why))")
            }
            switch entry.branchOutcome {
            case .none: break
            case .wouldRemove: lines.append("  branch:   would remove \(entry.branch ?? "")")
            case .removed: lines.append("  branch:   removed \(entry.branch ?? "")")
            case .kept(let why): lines.append("  branch:   kept (\(why))")
            }
            if let why = entry.recordFailed { lines.append("  record:   not written: \(why)") }
        }
        return lines
    }
}
