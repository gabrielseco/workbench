import Foundation
import Testing

@testable import WorkbenchCore

/// A `gh` stand-in for `gh pr list --head <branch>`: answers with `<dir>/<branch, / as _>.json`, or `[]`; fails while
/// `<dir>/fail` exists. Every call's arguments are appended to `<dir>/calls`.
private struct PruneGH {
    let dir: URL
    let runner: GitRunner

    init(_ fx: RunnerFixture) throws {
        dir = fx.repo.deletingLastPathComponent().appendingPathComponent("prune-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("gh")
        let body = """
            #!/bin/sh
            echo "$*" >> '\(dir.path)/calls'
            if [ -f '\(dir.path)/fail' ]; then echo 'HTTP 502 token ghp_zzz' >&2; exit 1; fi
            f='\(dir.path)/'"$(echo "$4" | tr / _)".json
            if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi

            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        runner = GitRunner(executable: script, environment: ["PATH": "/usr/bin:/bin", "GITHUB_TOKEN": "ghp_zzz"], timeout: 10)
    }

    func answer(_ branch: String, state: String, head: String, number: Int = 7) throws {
        let json = "[{\"number\":\(number),\"state\":\"\(state)\",\"headRefOid\":\"\(head)\"}]"
        try json.write(
            to: dir.appendingPathComponent(branch.replacingOccurrences(of: "/", with: "_") + ".json"), atomically: true,
            encoding: .utf8)
    }

    func failing() throws { try "".write(to: dir.appendingPathComponent("fail"), atomically: true, encoding: .utf8) }

    var calls: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

private func out(_ args: [String], _ dir: URL, _ fx: RunnerFixture) async throws -> String {
    try await fx.git.run(args, in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func run(_ args: [String], _ dir: URL, _ fx: RunnerFixture) async throws {
    let result = try await fx.git.run(args, in: dir)
    #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
}

/// Adds a worktree beside the repository on a new `branch` cut from main, with `commits` commits of its own; returns its
/// path (resolved, as git lists it) and tip.
private func worktree(
    _ name: String, branch: String?, commits: Int = 0, under: URL? = nil, _ fx: RunnerFixture
) async throws -> (path: URL, tip: String) {
    let parent = under ?? fx.repo.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let path = parent.resolvingSymlinksInPath().appendingPathComponent(name)
    if let branch {
        try await run(["worktree", "add", "-q", "-b", branch, path.path, "main"], fx.repo, fx)
    } else {
        try await run(["worktree", "add", "-q", "--detach", path.path, "main"], fx.repo, fx)
    }
    for index in 0..<commits {
        try "\(name) \(index)\n".write(to: path.appendingPathComponent("\(name)-\(index).txt"), atomically: true, encoding: .utf8)
        try await run(["add", "-A"], path, fx)
        try await run(["commit", "-q", "-m", "\(name) \(index)"], path, fx)
    }
    return (path, try await out(["rev-parse", "HEAD"], path, fx))
}

private func branchExists(_ name: String, _ fx: RunnerFixture) async throws -> Bool {
    try await fx.git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: fx.repo).succeeded
}

private func entry(_ report: PruneReport, _ path: URL) -> PruneEntry? {
    // macOS lists temporary paths as /private/var and /var; a removed one cannot be resolved any more.
    func plain(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
    return report.entries.first { plain($0.path) == plain(path.path) }
}

private func keptReason(_ report: PruneReport, _ path: URL) -> String? {
    guard case .kept(let why)? = entry(report, path)?.verdict else { return nil }
    return why
}

/// What git and the disk say about the repository's worktrees and branches.
private func snapshot(_ fx: RunnerFixture) async throws -> [String] {
    let listed = try await out(["worktree", "list", "--porcelain"], fx.repo, fx)
    let branches = try await out(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"], fx.repo, fx)
    let dirs = (try? FileManager.default.contentsOfDirectory(atPath: fx.project.worktreesDirectory.path)) ?? []
    return [listed, branches, dirs.sorted().joined(separator: ",")]
}

@Suite(.processGate) struct WorktreePruneTests {
    @Test func removableWorktreesGoWithTheirBranchesAndTheRestStay() async throws {
        let fx = try await RunnerFixture()
        let gh = try PruneGH(fx)
        // Merged into main by a fast-forward: an ancestor.
        let merged = try await worktree("merged", branch: "feat/merged", commits: 1, fx)
        try await run(["merge", "-q", "--ff-only", "feat/merged"], fx.repo, fx)
        // Squash-merged: not an ancestor, but its pull request is merged at its tip.
        let squash = try await worktree(
            "squash", branch: "feat/squash", commits: 2, under: fx.repo.appendingPathComponent(".claude/worktrees"), fx)
        try gh.answer("feat/squash", state: "MERGED", head: squash.tip, number: 3)
        let detached = try await worktree("detached", branch: nil, fx)
        let dirty = try await worktree("dirty", branch: "feat/dirty", fx)
        try "x\n".write(to: dirty.path.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let locked = try await worktree("locked", branch: "feat/locked", fx)
        try await run(["worktree", "lock", locked.path.path], fx.repo, fx)
        let open = try await worktree("open", branch: "feat/open", commits: 1, fx)
        try gh.answer("feat/open", state: "OPEN", head: open.tip)
        let nopr = try await worktree("nopr", branch: "feat/nopr", commits: 1, fx)

        let report = try await fx.service.prune(gh: gh.runner, includeClosed: false, unregistered: false, dryRun: false)

        for removed in [merged.path, squash.path, detached.path] {
            #expect(entry(report, removed)?.isRemovable == true, "\(removed.lastPathComponent): \(report.render())")
            #expect(entry(report, removed)?.outcome == .removed)
            #expect(!FileManager.default.fileExists(atPath: removed.path))
        }
        #expect(try await branchExists("feat/merged", fx) == false)
        #expect(try await branchExists("feat/squash", fx) == false)
        #expect(entry(report, merged.path)?.branchOutcome == .removed)

        #expect(keptReason(report, dirty.path) == "uncommitted changes")
        #expect(keptReason(report, locked.path) == "locked")
        #expect(keptReason(report, open.path) == "pull request #7 is open")
        #expect(keptReason(report, nopr.path) == "no pull request, and commits not on the default branch")
        #expect(entry(report, fx.repo)?.kind == .primary)
        for kept in [dirty.path, locked.path, open.path, nopr.path, fx.repo] {
            #expect(FileManager.default.fileExists(atPath: kept.path))
        }
        for branch in ["feat/dirty", "feat/locked", "feat/open", "feat/nopr", "main"] {
            #expect(try await branchExists(branch, fx), "\(branch)")
        }
        #expect(!report.lookupFailed)
        // An ancestor of main needs no question to GitHub.
        #expect(!gh.calls.contains { $0.contains("feat/merged") })
    }

    @Test func aDryRunListsEverythingAndChangesNothing() async throws {
        let fx = try await RunnerFixture()
        let gh = try PruneGH(fx)
        let merged = try await worktree("merged", branch: "feat/merged", fx)
        let squash = try await worktree("squash", branch: "feat/squash", commits: 1, fx)
        try gh.answer("feat/squash", state: "MERGED", head: squash.tip)
        let open = try await worktree("open", branch: "feat/open", commits: 1, fx)
        try gh.answer("feat/open", state: "OPEN", head: open.tip)
        try FileManager.default.createDirectory(
            at: fx.project.worktreesDirectory.appendingPathComponent("leftover"), withIntermediateDirectories: true)
        let before = try await snapshot(fx)

        let report = try await fx.service.prune(gh: gh.runner, includeClosed: true, unregistered: true, dryRun: true)

        #expect(try await snapshot(fx) == before)
        #expect(entry(report, merged.path)?.outcome == .wouldRemove)
        #expect(entry(report, merged.path)?.branchOutcome == .wouldRemove)
        #expect(entry(report, squash.path)?.outcome == .wouldRemove)
        #expect(entry(report, open.path)?.isRemovable == false)
        #expect(report.entries.contains { $0.kind == .unregistered && $0.isRemovable })
        // Every worktree git lists has a line.
        #expect(report.entries.filter { $0.kind != .unregistered }.count == 4)
        #expect(report.render().filter { $0.hasPrefix("removable") || $0.hasPrefix("kept") }.count == 5)
    }

    @Test func aClosedPullRequestIsRemovableOnlyWithClosed() async throws {
        let fx = try await RunnerFixture()
        let gh = try PruneGH(fx)
        let closed = try await worktree("closed", branch: "feat/closed", commits: 1, fx)
        try gh.answer("feat/closed", state: "CLOSED", head: closed.tip, number: 9)

        let kept = try await fx.service.prune(gh: gh.runner, includeClosed: false, unregistered: false, dryRun: false)
        #expect(keptReason(kept, closed.path) == "pull request #9 was closed without merging; --closed removes it")
        #expect(FileManager.default.fileExists(atPath: closed.path.path))

        let removed = try await fx.service.prune(gh: gh.runner, includeClosed: true, unregistered: false, dryRun: false)
        #expect(entry(removed, closed.path)?.outcome == .removed)
        #expect(try await branchExists("feat/closed", fx) == false)
    }

    @Test func aMergedPullRequestWithLaterCommitsIsKept() async throws {
        let fx = try await RunnerFixture()
        let gh = try PruneGH(fx)
        let later = try await worktree("later", branch: "feat/later", commits: 1, fx)
        try gh.answer("feat/later", state: "MERGED", head: later.tip)
        try "more\n".write(to: later.path.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)
        try await run(["add", "-A"], later.path, fx)
        try await run(["commit", "-q", "-m", "more"], later.path, fx)

        let report = try await fx.service.prune(gh: gh.runner, includeClosed: true, unregistered: false, dryRun: false)
        #expect(keptReason(report, later.path) == "it has commits after its pull request")
        #expect(try await branchExists("feat/later", fx))
    }

    @Test func aThreadWithAnActiveTurnKeepsItsWorktree() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options())
        let path = fx.project.worktreesDirectory.appendingPathComponent(id).resolvingSymlinksInPath()
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        _ = try await log.append(.turnStarted, turn: 2, data: ["session_id": "s", "resume": true])
        await log.close()

        let report = try await fx.service.prune(gh: nil, includeClosed: true, unregistered: true, dryRun: false)
        #expect(keptReason(report, path) == "thread \(id) has an active turn", "\(report.render())")
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(try await branchExists("workbench/\(id)", fx))
    }

    @Test func withoutGitHubOnlyWhatGitDecidesIsRemoved() async throws {
        let fx = try await RunnerFixture()
        let merged = try await worktree("merged", branch: "feat/merged", fx)
        let squash = try await worktree("squash", branch: "feat/squash", commits: 1, fx)

        let missing = try await fx.service.prune(gh: nil, includeClosed: false, unregistered: false, dryRun: false)
        #expect(missing.lookupFailed)
        #expect(entry(missing, squash.path)?.lookupFailed == true)
        #expect(keptReason(missing, squash.path)?.contains("GitHub could not be asked") == true)
        #expect(FileManager.default.fileExists(atPath: squash.path.path))
        #expect(entry(missing, merged.path)?.outcome == .removed)

        let gh = try PruneGH(fx)
        try gh.answer("feat/squash", state: "MERGED", head: squash.tip)
        try gh.failing()
        let failed = try await fx.service.prune(gh: gh.runner, includeClosed: false, unregistered: false, dryRun: false)
        #expect(failed.lookupFailed)
        let why = try #require(keptReason(failed, squash.path))
        #expect(!why.contains("ghp_zzz"), "\(why)")
        #expect(try await branchExists("feat/squash", fx))
    }

    @Test func unregisteredDirectoriesGoOnlyWithUnregisteredAndNeverAThreads() async throws {
        let fx = try await RunnerFixture()
        let folder = fx.project.worktreesDirectory
        let leftover = folder.appendingPathComponent("leftover")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "x\n".write(to: leftover.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let id = try await fx.service.newThread(name: "named")
        let named = folder.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)

        let listed = try await fx.service.prune(gh: nil, includeClosed: false, unregistered: false, dryRun: false)
        #expect(entry(listed, leftover)?.kind == .unregistered)
        #expect(keptReason(listed, leftover) == "unregistered; --unregistered removes it")
        #expect(FileManager.default.fileExists(atPath: leftover.path))

        let removed = try await fx.service.prune(gh: nil, includeClosed: false, unregistered: true, dryRun: false)
        #expect(entry(removed, leftover)?.outcome == .removed)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(keptReason(removed, named) == "unregistered, but thread \(id) names it")
        #expect(FileManager.default.fileExists(atPath: named.path))
    }

    @Test func aBranchNameThatDoesNotValidateIsKeptAndNeverAsked() async throws {
        let fx = try await RunnerFixture()
        let gh = try PruneGH(fx)
        // Git accepts `@` in a branch name; Workbench does not pass it on.
        let odd = try await worktree("odd", branch: "feat@odd", fx)

        let report = try await fx.service.prune(gh: gh.runner, includeClosed: true, unregistered: true, dryRun: false)
        #expect(keptReason(report, odd.path) == "its branch name is not one Workbench passes to git")
        #expect(FileManager.default.fileExists(atPath: odd.path.path))
        #expect(try await branchExists("feat@odd", fx))
        #expect(gh.calls.isEmpty)
    }

    @Test func aPathGitPrintsIsCheckedBeforeItGoesBack() {
        #expect(ThreadService.isSafeWorktreePath("/tmp/a/b"))
        #expect(!ThreadService.isSafeWorktreePath("relative/a"))
        #expect(!ThreadService.isSafeWorktreePath("/tmp/../etc"))
        #expect(!ThreadService.isSafeWorktreePath("/tmp/a\tb"))
        let parsed = ThreadService.parseWorktreeList(
            "worktree /r\nHEAD \(String(repeating: "a", count: 40))\nbranch refs/heads/main\n\n"
                + "worktree /w\nHEAD \(String(repeating: "b", count: 40))\ndetached\nlocked why\n\n")
        #expect(parsed.count == 2)
        #expect(parsed[0].branch == "main")
        #expect(parsed[1].branch == nil && parsed[1].locked)
    }

    @Test func theCommandExitsNonZeroWhenGitHubCannotBeAsked() async throws {
        let fx = try await RunnerFixture()
        let gh = try PruneGH(fx)
        try gh.failing()
        let merged = try await worktree("merged", branch: "feat/merged", fx)
        let squash = try await worktree("squash", branch: "feat/squash", commits: 1, fx)

        let dry = try await runPrune([], fx: fx, gh: gh.runner)
        #expect(dry.code == 1, "\(dry.text)")
        #expect(dry.text.contains("dry run"))
        #expect(FileManager.default.fileExists(atPath: merged.path.path))

        let done = try await runPrune(["--yes"], fx: fx, gh: gh.runner)
        #expect(done.code == 1, "\(done.text)")
        #expect(!FileManager.default.fileExists(atPath: merged.path.path))
        #expect(FileManager.default.fileExists(atPath: squash.path.path))
    }
}

private func runPrune(_ arguments: [String], fx: RunnerFixture, gh: GitRunner) async throws -> (code: Int32?, text: String) {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: ["prune"] + arguments,
        environment: [
            "PATH": "\(gh.executable.deletingLastPathComponent().path):/usr/bin:/bin",
            "HOME": NSHomeDirectory(), "USER": NSUserName(), "GITHUB_TOKEN": "ghp_zzz",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
        ],
        workingDirectory: fx.repo, timeout: 120)
    spawn.snapshotInterval = 3600
    let process = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var exit: ProcessExit?
    for await event in process.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event { exit = e }
    }
    var code: Int32?
    if case .exited(let c)? = exit?.termination { code = c }
    return (code, (lines + [exit?.stderrTail ?? ""]).joined(separator: "\n"))
}
