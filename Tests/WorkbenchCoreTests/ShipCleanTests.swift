import Foundation
import Testing

@testable import WorkbenchCore

/// `gh pr view` answers with the contents of `view`; a missing file makes it fail.
private func viewGH(_ fx: RunnerFixture, state: String?, head: String) throws -> GitRunner {
    let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("view-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("gh")
    let body =
        state.map { "echo '{\"state\":\"\($0)\",\"headRefOid\":\"\(head)\"}'" }
        ?? "echo 'HTTP 502 token ghp_zzz' >&2; exit 1"
    try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    return GitRunner(executable: script, environment: ["PATH": "/usr/bin:/bin", "GITHUB_TOKEN": "ghp_zzz"], timeout: 10)
}

private struct ShippedThread {
    var id: String
    var worktree: URL
    var head: String
}

private func shippedThread(_ fx: RunnerFixture) async throws -> ShippedThread {
    let gh = try FakeGH(in: fx)
    let (id, worktree) = try await acceptedThread(fx)
    _ = try await addOrigin(fx)
    _ = try await fx.service.shipPush(id: id, gh: gh.runner)
    _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
    let head = try await shipOut(["rev-parse", "HEAD"], worktree, fx)
    return ShippedThread(id: id, worktree: worktree, head: head)
}

private func branchExists(_ id: String, _ fx: RunnerFixture) async throws -> Bool {
    try await fx.git.run(["rev-parse", "--verify", "--quiet", "refs/heads/workbench/\(id)"], in: fx.repo).succeeded
}

@Suite struct ShipCleanTests {
    @Test func aMergedPullRequestLosesItsWorktreeAndBranch() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let gh = try viewGH(fx, state: "MERGED", head: t.head)

        let report = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: false))
        #expect(report.state == .merged)
        #expect(report.worktree == .removed(path: t.worktree.path))
        #expect(report.branch == .removed)
        #expect(!FileManager.default.fileExists(atPath: t.worktree.path))
        #expect(try await branchExists(t.id, fx) == false)
        let kinds = try fx.events(t.id).map(\.kind)
        #expect(kinds.filter { $0 == .worktreeRemoved }.count == 1)
        #expect(kinds.last == .branchRemoved)

        // Again: nothing is left, nothing is said.
        let again = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: false))
        #expect(!again.hasWork)
    }

    @Test func aDryRunChangesNothing() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let gh = try viewGH(fx, state: "MERGED", head: t.head)
        let before = try fx.events(t.id).count

        let report = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: true))
        #expect(report.branch == .wouldRemove)
        #expect(FileManager.default.fileExists(atPath: t.worktree.path))
        #expect(try await branchExists(t.id, fx))
        #expect(try fx.events(t.id).count == before)
    }

    @Test func anOpenPullRequestIsUntouched() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let gh = try viewGH(fx, state: "OPEN", head: t.head)

        let report = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: true, dryRun: false))
        #expect(report.state == .open)
        #expect(FileManager.default.fileExists(atPath: t.worktree.path))
        #expect(try await branchExists(t.id, fx))
    }

    @Test func aClosedPullRequestIsKeptUnlessAsked() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let gh = try viewGH(fx, state: "CLOSED", head: t.head)

        let kept = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: false))
        #expect(kept.state == .closed)
        #expect(try await branchExists(t.id, fx))
        #expect(FileManager.default.fileExists(atPath: t.worktree.path))

        let cleaned = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: true, dryRun: false))
        #expect(cleaned.branch == .removed)
        #expect(try await branchExists(t.id, fx) == false)
    }

    @Test func aBranchWithNewerCommitsIsKept() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let gh = try viewGH(fx, state: "MERGED", head: t.head)
        // The worktree is gone, and the branch moved on after shipping.
        #expect(await fx.service.cleanShipped(id: t.id, gh: nil) == .removed(path: t.worktree.path))
        let main = try await shipOut(["rev-parse", "HEAD"], fx.repo, fx)
        _ = try await fx.git.run(["update-ref", "refs/heads/workbench/\(t.id)", main], in: fx.repo)
        #expect(main != t.head)

        let report = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: false))
        guard case .kept = report.branch else { Issue.record("expected kept, got \(report.branch)"); return }
        #expect(try await branchExists(t.id, fx))
    }

    @Test func aPullRequestThatMovedOnRemovesNothing() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let gh = try viewGH(fx, state: "MERGED", head: String(repeating: "a", count: 40))

        let report = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: false))
        #expect(report.note != nil)
        #expect(FileManager.default.fileExists(atPath: t.worktree.path))
        #expect(try await branchExists(t.id, fx))
    }

    @Test func aGitHubFailureKeepsEverythingAndSaysWhy() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let failing = try viewGH(fx, state: nil, head: "")

        let report = try #require(await fx.service.cleanMerged(id: t.id, gh: failing, includeClosed: false, dryRun: false))
        #expect(report.state == nil)
        let note = try #require(report.note)
        #expect(note.contains("502"))
        #expect(!note.contains("ghp_zzz"))
        #expect(try await branchExists(t.id, fx))
        #expect(FileManager.default.fileExists(atPath: t.worktree.path))

        let missing = try #require(await fx.service.cleanMerged(id: t.id, gh: nil, includeClosed: false, dryRun: false))
        #expect(missing.note?.contains("gh") == true)
        #expect(try await branchExists(t.id, fx))
    }

    @Test func aTamperedRecordIsKeptNotFollowed() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let url = fx.project.eventsURL(t.id)
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: t.head, with: "--upload-pack=x")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let gh = try viewGH(fx, state: "MERGED", head: t.head)

        let report = await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: false)
        #expect(report?.note != nil)
        #expect(try await branchExists(t.id, fx))
        #expect(await fx.service.cleanMerged(id: "../x", gh: gh, includeClosed: false, dryRun: false) == nil)
    }

    @Test func theCommandIsADryRunUntilYes() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let gh = try viewGH(fx, state: "MERGED", head: t.head)

        func run(_ arguments: [String]) async throws -> (code: Int32?, text: String) {
            var spawn = SpawnRequest(
                executable: WorkbenchBinary.executable, arguments: ["clean"] + arguments,
                environment: [
                    "PATH": "\(gh.executable.deletingLastPathComponent().path):/usr/bin:/bin",
                    "HOME": NSHomeDirectory(), "USER": NSUserName(),
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

        let dry = try await run([])
        #expect(dry.code == 0)
        #expect(dry.text.contains("would remove workbench/\(t.id)"))
        #expect(dry.text.contains("dry run"))
        #expect(try await branchExists(t.id, fx))

        let real = try await run(["--yes"])
        #expect(real.code == 0)
        #expect(real.text.contains("removed workbench/\(t.id)"))
        #expect(try await branchExists(t.id, fx) == false)
        #expect(try await run(["--yes"]).text.contains("nothing to clean"))
    }

    @Test func aDryRunDoesNotPromiseWhatADirtyWorktreeBlocks() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let gh = try viewGH(fx, state: "MERGED", head: t.head)
        try "scratch".write(to: t.worktree.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let dry = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: true))
        guard case .kept = dry.worktree, case .kept = dry.branch else {
            Issue.record("expected both kept, got \(String(describing: dry.worktree)) / \(dry.branch)")
            return
        }
        let real = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: false))
        #expect(real.worktree == dry.worktree)
        #expect(real.branch == dry.branch)
        #expect(try await branchExists(t.id, fx))
    }

    @Test func aRemovalThatWasNotRecordedIsRecordedByTheNextClean() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        let gh = try viewGH(fx, state: "MERGED", head: t.head)
        // The process died after `git worktree remove` and before the event.
        _ = try await fx.git.run(["worktree", "remove", t.worktree.path], in: fx.repo)
        #expect(try fx.events(t.id).contains { $0.kind == .worktreeRemoved } == false)

        _ = try #require(await fx.service.cleanMerged(id: t.id, gh: gh, includeClosed: false, dryRun: false))
        let kinds = try fx.events(t.id).map(\.kind)
        #expect(kinds.filter { $0 == .worktreeRemoved }.count == 1)
        #expect(try await branchExists(t.id, fx) == false)
    }

    @Test func theBranchIsDeletedOnlyAtTheCommitThatWasInspected() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        #expect(await fx.service.cleanShipped(id: t.id, gh: nil) == .removed(path: t.worktree.path))
        let main = try await shipOut(["rev-parse", "HEAD"], fx.repo, fx)

        // A stale inspection: the tip is no longer what was looked at.
        #expect(await fx.service.deleteBranch(id: t.id, at: main) != nil)
        #expect(try await branchExists(t.id, fx))
        #expect(await fx.service.deleteBranch(id: t.id, at: t.head) == nil)
        #expect(try await branchExists(t.id, fx) == false)
    }

    @Test func aBranchCheckedOutElsewhereIsNotDeleted() async throws {
        let fx = try await RunnerFixture()
        let t = try await shippedThread(fx)
        // The thread's own worktree still has it checked out.
        #expect(await fx.service.deleteBranch(id: t.id, at: t.head) != nil)
        #expect(try await branchExists(t.id, fx))
    }
}
