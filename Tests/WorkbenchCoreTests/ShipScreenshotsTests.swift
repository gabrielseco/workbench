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

/// What one verifier run records for a turn: its `proof.added` lines (marked `source: verifier`) for the files it
/// wrote, at the work as it is now, and its end. A rerun records only what it wrote again.
private func recordVerifierProof(_ fx: RunnerFixture, _ id: String, _ files: [String: String], turn: Int = 1) async throws {
    let proof = fx.project.proofDirectory(id, turn: turn)
    try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
    for (name, text) in files { try Data(text.utf8).write(to: proof.appendingPathComponent(name)) }
    let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
    let identity = await ProofIdentity.of(worktree: worktree, git: fx.git, attributesFrom: nil)
    let commit: JSONValue = identity.map { .string($0.commit) } ?? .null
    let tree: JSONValue = identity.map { .string($0.tree) } ?? .null
    let recorded = ProofCollector.collect(proofDirectory: proof, threadDirectory: fx.project.threadDirectory(id)).files
        .filter { files[$0.name] != nil }
    let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
    try await log.append(.verifierStarted, turn: turn, data: ["argv": ["claude"]])
    for file in recorded {
        try await log.append(
            .proofAdded, turn: turn,
            data: [
                "name": .string(file.name), "path": .string(file.path), "sha256": .string(file.sha256),
                "bytes": .int(file.bytes), "commit": commit, "tree": tree, "source": "verifier",
            ])
    }
    try await log.append(.verifierEnded, turn: turn, data: ["ok": true, "report": "c1: holds"])
    await log.close()
}

private func shippedThread(
    _ files: [String: String] = ["home.png": "pixels"], verifier: Bool = false
) async throws -> Shipped {
    let fx = try await RunnerFixture()
    // The turn itself changes the work, as a real one does, so verify sees the work that is then accepted.
    let id = try await fx.approvedThread()
    _ = try await fx.runner(id).run(fx.options("write=a.txt"))
    if verifier {
        try await recordVerifierProof(fx, id, files)
    } else {
        try await recordLegacyVerify(fx, id, files)
    }
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

    @Test func theVerifiersPNGsAreAttachedWhenThereIsNoVerifyStep() async throws {
        let shipped = try await shippedThread(["home.png": "pixels", "report.md": "x"], verifier: true)
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let tool = try FakeShots(in: fx)
        let result = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 7, tool: tool.runner)

        #expect(result == .attached(count: 1))
        #expect(tool.shot("home") == "pixels")
        let event = try #require(try fx.events(id).last { $0.kind == .proofPublished })
        #expect(event.data["number"]?.intValue == 7)
        #expect(event.data["files"] == ["home.png"])
    }

    @Test func theLatestTurnsVerifierProofIsAttachedAndAnEarlierTurnsAloneIsNot() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("write=a.txt"))
        try await recordLegacyVerify(fx, id, ["old.png": "turn one"])
        _ = try await fx.runner(id).run(fx.options("write=a.txt", feedback: "more"))
        try await recordVerifierProof(fx, id, ["new.png": "turn two"], turn: 2)
        try await fx.service.accept(id: id, message: "chore: work")
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        let tool = try FakeShots(in: fx)

        // Turn 2's verifier proof is the latest turn's, so it is attached, and turn 1's verify step's is not.
        let result = await fx.service.shipScreenshots(id: id, worktree: worktree, number: 7, tool: tool.runner)
        #expect(result == .attached(count: 1))
        #expect(tool.shot("new") == "turn two")
        #expect(tool.shot("old") == nil)
        let event = try #require(try fx.events(id).last { $0.kind == .proofPublished })
        #expect(event.data["files"] == ["new.png"])

        // A later turn with no proof of its own: what turn 2 took is about other work.
        let log = try EventLogWriter.open(at: fx.project.eventsURL(id))
        try await log.append(.turnStarted, turn: 3, data: [:])
        try await log.append(.turnEnded, turn: 3, data: ["result": "succeeded"])
        await log.close()
        let calls = tool.calls.count
        #expect(await fx.service.shipScreenshots(id: id, worktree: worktree, number: 7, tool: tool.runner) == .none)
        #expect(tool.calls.count == calls)
    }

    /// The verifier takes `a.png` and `b.png`, the work changes, and a rerun in the same turn takes only `retaken`
    /// again: the other file is of the earlier work, whichever comes first in the set.
    @Test(arguments: ["a", "b"])
    func aScreenshotTakenBeforeTheWorkChangedIsLeftOutAndNamed(retaken: String) async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        _ = try await fx.runner(id).run(fx.options("write=a.txt"))
        try await recordVerifierProof(fx, id, ["a.png": "a before", "b.png": "b before"])
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        try "changed after the first verifier run\n".write(
            to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await recordVerifierProof(fx, id, ["\(retaken).png": "\(retaken) after"])
        try await fx.service.accept(id: id, message: "chore: work")
        let stale = retaken == "a" ? "b" : "a"
        let tool = try FakeShots(in: fx)

        let result = await fx.service.shipScreenshots(id: id, worktree: worktree, number: 7, tool: tool.runner)

        guard case .attached(let count, let note?) = result else {
            Issue.record("expected attached with a note, got \(result)")
            return
        }
        #expect(count == 1)
        #expect(note.contains("\(stale).png") && !note.contains("\(retaken).png"), "\(note)")
        #expect(note.contains("work has changed since") && note.contains("ship --screenshots"), "\(note)")
        #expect(tool.shot(retaken) == "\(retaken) after")
        #expect(tool.shot(stale) == nil, "the stale screenshot is not published")
        let event = try #require(try fx.events(id).last { $0.kind == .proofPublished })
        #expect(event.data["files"] == .array([.string("\(retaken).png")]))
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

    @Test func aPullRequestWhoseBranchCannotBeReadOnOriginGetsNoScreenshots() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        // The log says a pull request was opened, and this repository has no origin to ask.
        _ = try await fx.service.withLog(id) { log in
            try await log.append(.prOpened, data: ["branch": .string("workbench/\(id)"), "number": 12])
        }
        let tool = try FakeShots(in: fx)
        let result = await fx.service.shipScreenshots(id: id, worktree: plan.worktree, number: 12, tool: tool.runner)
        guard case .skipped(let why) = result else { Issue.record("expected skipped, got \(result)"); return }
        #expect(why.contains("could not be read"))
        #expect(tool.calls.isEmpty)
    }

    @Test func reviewStillSaysCurrentOrStaleAfterShipRemovedTheWorktree() async throws {
        let shipped = try await shippedThread()
        let (fx, id, plan) = (shipped.fx, shipped.id, shipped.plan)
        let loader = ReviewLoader(project: fx.project, git: fx.git)
        #expect(await loader.load(id: id).proofFreshness == .current)

        _ = try await fx.git.run(["worktree", "remove", "--force", plan.worktree.path], in: fx.repo)
        #expect(!FileManager.default.fileExists(atPath: plan.worktree.path))
        #expect(await loader.load(id: id).proofFreshness == .current)

        // The branch moves on after the proof: the retained branch shows it.
        let other = fx.repo.deletingLastPathComponent().appendingPathComponent("later-\(UUID().uuidString)")
        _ = try await fx.git.run(["worktree", "add", "-q", other.path, "workbench/\(id)"], in: fx.repo)
        try "later\n".write(to: other.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["commit", "-qam", "later"], in: other)
        _ = try await fx.git.run(["worktree", "remove", "--force", other.path], in: fx.repo)
        #expect(await loader.load(id: id).proofFreshness == .stale)
    }
}
