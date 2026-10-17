import Foundation
import Testing

@testable import WorkbenchCore

/// A `pr-shots` that names files under its own directory and records what it was asked.
private struct FakeShots {
    let dir: URL
    let runner: GitRunner

    init(
        in fx: RunnerFixture, failing: Bool = false, badPath: Bool = false, ghRepo: String? = nil,
        hidesFromList: Bool = false
    ) throws {
        dir = fx.repo.deletingLastPathComponent().appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out"), withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("pr-shots")
        try """
            #!/bin/sh
            echo "$(pwd -P): $@" >> "\(dir.path)/calls"
            case "$1" in
            path) \(badPath ? "echo relative.png" : "echo \"$PR_SHOTS_DIR/proj/branch-$2-sha.png\"") ;;
            list) \(hidesFromList ? "exit 0" : "ls \"$PR_SHOTS_DIR\"/proj/*.png") ;;
            pr)
              echo "gh_repo=${GH_REPO:-unset}" > "\(dir.path)/env"
              ls "$PR_SHOTS_DIR/proj" > "\(dir.path)/listing"
              cp "$PR_SHOTS_DIR/proj/"*.png "\(dir.path)/out/" 2>/dev/null
              \(failing ? "echo 'no store configured' >&2; exit 1" : "exit 0") ;;
            esac
            """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        var env = ["PATH": "/usr/bin:/bin"]
        if let ghRepo { env["GH_REPO"] = ghRepo }
        runner = GitRunner(executable: script, environment: env, timeout: 10)
    }

    var seenEnv: String { (try? String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8)) ?? "" }
    var listing: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("listing"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    var calls: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func shot(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("out/branch-\(name)-sha.png"), encoding: .utf8)
    }
}

private struct Shipped {
    var fx: RunnerFixture
    var id: String
    var plan: ShipPlan
}

private func shippedThread(_ files: [String: String] = ["home.png": "pixels"]) async throws -> Shipped {
    let writes = files.map { "printf '\($0.value)' > \"$WORKBENCH_PROOF_DIR/\($0.key)\"" }.joined(separator: "\n")
    let script = try CheckScript()
    let verify = try script.write(writes, name: "verify.sh")
    let fx = try await RunnerFixture(extraConfig: "verify_command = \"\(verify)\"")
    // The turn itself changes the work, as a real one does, so verify sees the work that is then accepted.
    let id = try await fx.approvedThread()
    _ = try await fx.runner(id).run(fx.options("write=a.txt"))
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    try await fx.service.accept(id: id, message: "chore: work")
    let plan = ShipPlan(
        id: id, worktree: worktree, branch: "workbench/\(id)", remoteBranch: "workbench/\(id)", base: "main",
        head: "abc", origin: "o", remote: .absent)
    return Shipped(fx: fx, id: id, plan: plan)
}

@Suite struct ShipScreenshotsTests {
    @Test func theVerifyStepsPNGsAreCopiedToPrShotsNamesAndPublished() async throws {
        let shipped = try await shippedThread(["home.png": "pixels", "notes.txt": "x", "verdict.json": "{}"])
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx)
        let result = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 12, tool: tool.runner)

        #expect(result == .attached(count: 1))
        #expect(tool.shot("home") == "pixels", "copied to where `pr-shots path home` said")
        let asked = tool.calls.map { $0.split(separator: ":", maxSplits: 1).last.map(String.init) }
        #expect(asked == [" path home", " list", " pr 12"])
        let here = OrphanSweeper.realPath(plan.worktree)
        #expect(tool.calls.allSatisfy { $0.hasPrefix(here + ":") }, "run in the thread's worktree: \(tool.calls)")
        let event = try #require(try fx.events(id).last { $0.kind == .proofPublished })
        #expect(event.data["number"]?.intValue == 12)
        #expect(event.data["files"] == ["home.png"])
    }

    @Test func onlyTheRecordedFilesAreInTheToolsFolderAndGHRepoIsDropped() async throws {
        let shipped = try await shippedThread(["home.png": "pixels"])
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx, ghRepo: "someone/else")
        _ = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 12, tool: tool.runner)
        #expect(tool.listing == ["branch-home-sha.png"], "an older screenshot elsewhere is not in the upload")
        #expect(tool.seenEnv == "gh_repo=unset\n", "GH_REPO would point `gh pr edit` at another repository")
    }

    @Test func aWorktreeConfigDifferentFromTheProjectsStopsTheUpload() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        try #"{"store":"s3","bucket":"public-bucket"}"#.write(
            to: plan.worktree.appendingPathComponent(".pr-shots.json"), atomically: true, encoding: .utf8)
        let tool = try FakeShots(in: fx)
        let result = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 1, tool: tool.runner)
        guard case .skipped(let why) = result else {
            Issue.record("expected skipped, got \(result)")
            return
        }
        #expect(why.contains(".pr-shots.json") && why.contains("ship --screenshots"))
        #expect(tool.calls.isEmpty)

        // The same file in the project checkout is the person's own choice.
        try #"{"store":"s3","bucket":"public-bucket"}"#.write(
            to: fx.repo.appendingPathComponent(".pr-shots.json"), atomically: true, encoding: .utf8)
        #expect(
            await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 1, tool: tool.runner)
                == .attached(count: 1))
    }

    @Test func aFileTheToolWouldLeaveOutIsNotReportedAsAttached() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx, hidesFromList: true)
        let result = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 1, tool: tool.runner)
        guard case .skipped(let why) = result else {
            Issue.record("expected skipped, got \(result)")
            return
        }
        #expect(why.contains("leave some screenshots out"))
        #expect(!tool.calls.contains { $0.hasSuffix(" pr 1") }, "nothing was uploaded")
        #expect(try !fx.events(id).contains { $0.kind == .proofPublished })
    }

    @Test func aPathOutsideTheToolsFolderIsNotWrittenTo() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx, badPath: true)
        let result = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 1, tool: tool.runner)
        guard case .skipped = result else {
            Issue.record("expected skipped, got \(result)")
            return
        }
    }

    @Test func noScreenshotsMeansNothingIsRunOrSaid() async throws {
        let shipped = try await shippedThread(["notes.txt": "x"])
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx)
        #expect(await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 1, tool: tool.runner) == .none)
        #expect(tool.calls.isEmpty)
    }

    @Test func aThreadWithNoVerifyStepIsLeftAlone() async throws {
        let fx = try await RunnerFixture()
        let (id, worktree) = try await acceptedThread(fx)
        let plan = ShipPlan(
            id: id, worktree: worktree, branch: "b", remoteBranch: "b", base: "main", head: "abc", origin: "o",
            remote: .absent)
        let tool = try FakeShots(in: fx)
        #expect(await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 1, tool: tool.runner) == .none)
    }

    @Test func aMissingToolIsANoteNotAnError() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let result = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 1, tool: nil)
        guard case .skipped(let why) = result else {
            Issue.record("expected skipped, got \(result)")
            return
        }
        #expect(why.contains("pr-shots") && why.contains("1 screenshot not attached"))
        #expect(try !fx.events(id).contains { $0.kind == .proofPublished })
    }

    @Test func aFailedUploadIsANoteAndRecordsNothing() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx, failing: true)
        let result = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 5, tool: tool.runner)
        guard case .skipped(let why) = result else {
            Issue.record("expected skipped, got \(result)")
            return
        }
        #expect(why.contains("no store configured"))
        #expect(try !fx.events(id).contains { $0.kind == .proofPublished })
    }

    @Test func aFileNameThatIsNotAbsoluteIsNotCopiedTo() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx, badPath: true)
        let result = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 5, tool: tool.runner)
        guard case .skipped(let why) = result else {
            Issue.record("expected skipped, got \(result)")
            return
        }
        #expect(why.contains("no usable file name"))
        #expect(!tool.calls.contains { $0.hasSuffix(" pr 5") })
    }

    @Test func aScreenshotRemovedSinceTheVerifyIsNotPublished() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let events = try fx.events(id)
        let shot = try #require(events.last { $0.kind == .proofAdded }?.data["path"]?.stringValue)
        try FileManager.default.removeItem(at: fx.project.threadDirectory(id).appendingPathComponent(shot))
        let tool = try FakeShots(in: fx)
        #expect(await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 1, tool: tool.runner) == .none)
        #expect(tool.calls.isEmpty)
    }
}

@Suite struct ShipScreenshotsRetryTests {
    private func run(_ arguments: [String], in fx: RunnerFixture) async throws -> (code: Int32?, text: String) {
        var spawn = SpawnRequest(
            executable: WorkbenchBinary.executable, arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
            workingDirectory: fx.repo, timeout: 120)
        spawn.snapshotInterval = 3600
        var lines: [String] = []
        var exit: ProcessExit?
        for await event in try ProcessRunner.start(spawn).events {
            if case .line(let line) = event { lines.append(line) }
            if case .exited(let e) = event { exit = e }
        }
        var code: Int32?
        if case .exited(let c)? = exit?.termination { code = c }
        return (code, lines.joined(separator: "\n") + (exit?.stderrTail ?? ""))
    }

    @Test func retryingNeedsAPullRequest() async throws {
        let shipped = try await shippedThread()
        let result = try await run(["ship", shipped.id, "--screenshots"], in: shipped.fx)
        #expect(result.code != 0)
        #expect(result.text.contains("no pull request yet"), "\(result.text)")
    }

    @Test func retryingTellsWhyTheyAreStillNotAttached() async throws {
        let shipped = try await shippedThread()
        let (fx, id) = (shipped.fx, shipped.id)
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(
            .prOpened,
            data: [
                "url": "https://github.com/o/r/pull/12", "number": 12, "branch": "b", "base": "main",
                "head_sha": "abc",
            ])
        await log.close()
        // `pr-shots` is not on the test's PATH.
        let result = try await run(["ship", id, "--screenshots"], in: fx)
        #expect(result.code == 1, "\(result.text)")
        #expect(result.text.contains("`pr-shots` is not on PATH"), "\(result.text)")
        #expect(result.text.contains("workbench ship --screenshots"), "the worktree is kept for another try")
    }
}

@Suite struct ShipScreenshotsFreshnessTests {
    @Test func aCommitAfterVerifyKeepsTheScreenshotsOutOfThePullRequest() async throws {
        let shipped = try await shippedThread()
        let fx = shipped.fx
        // The work moves on after the screenshots were taken.
        try "changed after verify\n".write(
            to: shipped.plan.worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["commit", "-qam", "later"], in: shipped.plan.worktree)
        let tool = try FakeShots(in: fx)

        let result = await fx.service.shipScreenshots(
            id: shipped.id, worktree: shipped.plan.worktree, number: 12, tool: tool.runner)

        guard case .skipped(let why) = result else { Issue.record("expected skipped, got \(result)"); return }
        #expect(why.contains("work has changed since"))
        #expect(why.contains("ship --screenshots"))
        #expect(tool.calls.isEmpty)
        #expect(try fx.events(shipped.id).allSatisfy { $0.kind != .proofPublished })
    }

    @Test func screenshotsTakenAtTheShippedWorkAreAttached() async throws {
        let shipped = try await shippedThread()
        let tool = try FakeShots(in: shipped.fx)
        let result = await shipped.fx.service.shipScreenshots(
            id: shipped.id, worktree: shipped.plan.worktree, number: 12, tool: tool.runner)
        #expect(result == .attached(count: 1))
    }

    @Test func aPullRequestBranchThatMovedOnIsNotGivenTheseScreenshots() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let branch = "workbench/\(id)"
        let root = fx.repo.deletingLastPathComponent()
        let bare = root.appendingPathComponent("origin-\(UUID().uuidString).git")
        _ = try await fx.git.run(["init", "-q", "--bare", bare.path], in: fx.repo)
        _ = try await fx.git.run(["remote", "add", "origin", bare.path], in: fx.repo)
        _ = try await fx.git.run(["push", "-q", "origin", branch], in: plan.worktree)
        _ = try await fx.service.withLog(id) { log in
            try await log.append(.prOpened, data: ["branch": .string(branch), "number": 12])
        }
        let tool = try FakeShots(in: fx)

        // Origin has the work the screenshots were taken at: attached.
        #expect(
            await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 12, tool: tool.runner)
                == .attached(count: 1))

        // A follow-up pushes to the same pull request from another clone; this thread's worktree is as it was.
        let clone = root.appendingPathComponent("clone-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", "--branch", branch, bare.path, clone.path], in: root)
        try "follow-up\n".write(to: clone.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["commit", "-qam", "follow-up"], in: clone)
        _ = try await fx.git.run(["push", "-q", "origin", branch], in: clone)
        let later = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 12, tool: tool.runner)
        guard case .skipped(let why) = later else { Issue.record("expected skipped, got \(later)"); return }
        #expect(why.contains("branch is at"))
        #expect(tool.calls.count == 3)  // only the first call's `path`, `list` and `pr`
    }
}
