import Foundation
import Testing

@testable import WorkbenchCore

/// A `fix: update` task in a project with a bare origin that holds `feature/pr`, a branch one commit off main.
private struct Update {
    let fx: RunnerFixture
    let task: TaskFixture
    let gh: FakeGH
    let origin: URL

    init(front: String = "fix: update\npending: pending.sh") async throws {
        fx = try await RunnerFixture(extraConfig: "max_active_threads = 1\ncheck_command = \"true\"")
        origin = try await originWithBranch(fx)
        gh = try FakeGH(in: fx)
        task = try TaskFixture(in: fx.project, front: front)
        try task.script(#"echo '[{"id":"PR12-abc","title":"a pull request","branch":"feature/pr"}]'"#)
        try await task.library.approve(task.name)
        try """
            [{"number":12,"url":"https://github.com/o/r/pull/12","headRefName":"feature/pr","baseRefName":"main","title":"t","body":"b"}]
            """.write(to: gh.dir.appendingPathComponent("list"), atomically: true, encoding: .utf8)
    }

    func runner(_ directives: String = "") -> TaskRunner {
        var runner = TaskRunner(project: fx.project, git: fx.git, gh: gh.runner)
        runner.runOptions = fx.options(directives)
        runner.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        return runner
    }

    /// A commit on main (pushed) that writes `text` to `file`.
    func moveMain(file: String, text: String) async throws {
        try text.write(to: fx.repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", file], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "main moves: \(file)"], in: fx.repo)
        _ = try await fx.git.run(["push", "-q", "origin", "main"], in: fx.repo)
    }

    /// The branch and main both change a.txt, differently.
    func makeConflict() async throws {
        let scratch = fx.repo.deletingLastPathComponent().appendingPathComponent("edit-\(UUID().uuidString)")
        _ = try await fx.git.run(["worktree", "add", "-q", "--detach", scratch.path, "origin/feature/pr"], in: fx.repo)
        try "branch side\n".write(to: scratch.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["commit", "-qam", "branch edits a"], in: scratch)
        _ = try await fx.git.run(["push", "-q", "origin", "HEAD:refs/heads/feature/pr"], in: scratch)
        _ = try await fx.git.run(["worktree", "remove", "--force", scratch.path], in: fx.repo)
        try await moveMain(file: "a.txt", text: "main side\n")
    }

    func originTip(_ branch: String) async throws -> String {
        try await fx.git.run(["rev-parse", "refs/heads/\(branch)"], in: origin).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func originHas(_ branch: String, _ ancestor: String) async throws -> Bool {
        try await fx.git.run(["merge-base", "--is-ancestor", ancestor, "refs/heads/\(branch)"], in: origin).succeeded
    }
}

@Suite(.processGate) struct TaskUpdateTests {
    @Test func aCleanMergeIsPushedToThePullRequestsOwnBranchAndOpensNothing() async throws {
        let up = try await Update()
        try await up.moveMain(file: "c.txt", text: "from main\n")
        let main = try await up.originTip("main")
        let before = try await up.originTip("feature/pr")

        let result = await up.runner().run("bump", trigger: .tick)

        #expect(result.outcome == .prOpened, "\(result.reason ?? "")")
        #expect(result.pullRequest == "https://github.com/o/r/pull/12")
        #expect(result.reason == "updated feature/pr with origin/main")
        let after = try await up.originTip("feature/pr")
        let keepsTheOldWork = try await up.originHas("feature/pr", before)
        let hasMain = try await up.originHas("feature/pr", main)
        #expect(after != before && keepsTheOldWork && hasMain)
        let branches = try await originBranches(up.origin, up.fx)
        #expect(!branches.contains { $0.hasPrefix("refs/heads/workbench/") }, "the thread's own branch is never pushed")
        #expect(up.gh.count("pr create") == 0)
    }

    @Test func aBranchThatAlreadyHasMainIsLeftAloneAndTheThreadGoes() async throws {
        let up = try await Update()
        let before = try await up.originTip("feature/pr")
        _ = try await up.fx.git.run(["fetch", "-q", "origin"], in: up.fx.repo)
        // feature/pr was cut from main and main has not moved: there is nothing to bring in.
        let result = await up.runner().run("bump", trigger: .tick)
        #expect(result.outcome == .nothingToDo, "\(result.reason ?? "")")
        let after = try await up.originTip("feature/pr")
        #expect(after == before)
    }

    @Test func aConflictTheAgentLeavesOpenIsNeedsYouAndNothingIsPushed() async throws {
        let up = try await Update()
        try await up.makeConflict()
        let before = try await up.originTip("feature/pr")

        // The fake agent resolves nothing, which is what an agent that sees real logic on both sides does.
        let result = await up.runner().run("bump", trigger: .tick)

        #expect(result.outcome == .needsYou, "\(result.reason ?? "")")
        #expect(result.reason?.contains("a.txt") == true)
        let after = try await up.originTip("feature/pr")
        #expect(after == before, "the pull request's branch is as it was")
        #expect(up.gh.count("pr create") == 0)
        // The unit is not tried again for the same main.
        let history = try up.task.log.history()
        #expect(history.openedUnits.contains("PR12-abc"))
    }

    @Test func aConflictResolvedToExactlyTheBranchsOwnContentStillLandsMainsHistory() async throws {
        let up = try await Update()
        try await up.makeConflict()
        let main = try await up.originTip("main")
        let before = try await up.originTip("feature/pr")

        // Keeping the branch's side leaves a tree equal to the branch's: `accept` alone would commit nothing and drop the merge.
        let result = await up.runner("resolve=a.txt").run("bump", trigger: .tick)

        #expect(result.outcome == .prOpened, "\(result.reason ?? "")")
        let hasMain = try await up.originHas("feature/pr", main)
        let keepsOld = try await up.originHas("feature/pr", before)
        #expect(hasMain && keepsOld, "the pushed branch carries main's history")
        let content = try await up.fx.git.run(["show", "refs/heads/feature/pr:a.txt"], in: up.origin).stdout
        #expect(content.trimmingCharacters(in: .whitespacesAndNewlines) == "branch side")
    }

    @Test func aResolutionThatChangesAFileMainDidNotChangeIsRefusedBeforeThePush() async throws {
        let up = try await Update()
        try await up.moveMain(file: "c.txt", text: "from main\n")
        let before = try await up.originTip("feature/pr")

        // The agent was asked to change nothing; this one writes a.txt, which main never touched.
        let result = await up.runner("write=a.txt").run("bump", trigger: .tick)

        #expect(result.outcome == .failed, "\(result.reason ?? "")")
        #expect(result.reason?.contains("a.txt") == true)
        let after = try await up.originTip("feature/pr")
        #expect(after == before)
    }

    @Test func aUnitWithoutABranchFailsBeforeAnyThreadExists() async throws {
        let up = try await Update()
        try up.task.script(#"echo '[{"id":"PR12-abc","title":"no branch"}]'"#)
        try await up.task.library.approve(up.task.name)
        let result = await up.runner().run("bump", trigger: .tick)
        #expect(result.outcome == .failed && result.reason?.contains("branch") == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: up.fx.project.threadsDirectory.path)) ?? []).isEmpty)
    }
}

struct TaskUpdateParseTests {
    private func problems(_ front: String) -> [String] {
        do {
            _ = try TaskDefinition.parse("---\n\(front)\n---\nx\n", name: "sync")
            return []
        } catch let error as TaskParseError { return error.problems.map(\.description) } catch { return ["\(error)"] }
    }

    @Test func anUpdateTaskNeedsAPendingScriptAndOneUnitAtATime() {
        #expect(problems("fix: update\npending: p.sh").isEmpty)
        #expect(problems("fix: update").contains { $0.contains("needs 'pending'") })
        #expect(problems("fix: update\npending: p.sh\nbatch: 2").contains { $0.contains("'batch' must be 1") })
    }

    @Test func anUpdateTaskOpensNoPullRequestSoLabelsAndMaxOpenAreRefused() {
        let found = problems("fix: update\npending: p.sh\nlabels: [x]\nmax_open: 2\nhistory: 2")
        #expect(found.contains { $0.contains("'labels' is for 'fix: pr'") })
        #expect(found.contains { $0.contains("'max_open' is for 'fix: pr'") })
        #expect(found.contains { $0.contains("'history'") })
    }

    @Test func aUnitsBranchMustBeSafeToPushTo() throws {
        let ok = #"[{"id":"a","title":"t","branch":"feature/x"}]"#
        #expect(try PendingUnits.parse(Data(ok.utf8)).first?.branch == "feature/x")
        for bad in ["main", "-f", "a b", "x..y"] {
            let json = #"[{"id":"a","title":"t","branch":"\#(bad)"}]"#
            #expect(throws: PendingScriptError.self) { try PendingUnits.parse(Data(json.utf8)) }
        }
    }

    @Test func aConflictedPathThatIsNotAPlainSmallFileCountsAsUnresolvedAndIsNeverFollowedOrBlockedOn() throws {
        let dir = try Scratch.directory("guard")
        try "fine\n".write(to: dir.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.txt"), withDestinationURL: dir.appendingPathComponent("ok.txt"))
        #expect(mkfifo(dir.appendingPathComponent("pipe.txt").path, 0o644) == 0)
        try String(repeating: "x", count: UpdateGuard.maxFileBytes + 1).write(
            to: dir.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let found = UpdateGuard.unresolved(files: ["ok.txt", "link.txt", "pipe.txt", "big.txt", "missing.txt", "../x"], in: dir)
        #expect(found == ["link.txt", "pipe.txt", "big.txt", "missing.txt", "../x"])
    }

    @Test func conflictMarkersAreFoundAtTheStartOfALineOnly() {
        #expect(UpdateGuard.hasMarker("a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> origin/main\n"))
        #expect(UpdateGuard.hasMarker("a\n=======\nb"))
        #expect(!UpdateGuard.hasMarker("a = \"<<<<<<< not at the start\"\nb == ======= c\n"))
        #expect(!UpdateGuard.hasMarker("# Title\n==========\n"))
    }
}
