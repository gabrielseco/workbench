import Foundation
import Testing

@testable import WorkbenchCore

/// Two stacked steps in a fixture repository with a local origin: step 2's branch was cut from step 1's tip, then step 1 was
/// squash-merged into `main` (a new commit, so a plain rebase would replay step 1's commit again).
private struct Stack {
    var fx: RunnerFixture
    var library: SeriesLibrary
    var bare: URL
    var ghDir: URL
    var gh: GitRunner
    var tipA = ""
    var tipB = ""
    let parent = "g-2026-11-21-s-1"
    let child = "g-2026-11-21-s-2"

    func git(_ arguments: [String], in dir: URL? = nil) async throws -> String {
        try await shipOut(arguments, dir ?? fx.repo, fx)
    }

    init(conflict: Bool = false, mergeParent: Bool = true) async throws {
        fx = try await RunnerFixture(extraConfig: #"check_command = "true""#)
        bare = try await addOrigin(fx)
        library = SeriesLibrary(project: fx.project)
        ghDir = fx.repo.deletingLastPathComponent().appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ghDir, withIntermediateDirectories: true)
        let script = ghDir.appendingPathComponent("gh")
        try """
            #!/bin/sh
            d="$GH_FAKE_DIR"
            echo "$@" >> "$d/calls"
            case "$1 $2" in
            "pr view") cat "$d/view_$3"; exit 0 ;;
            "pr edit") echo "$5" > "$d/edit_$3"; exit 0 ;;
            esac
            exit 2
            """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        gh = GitRunner(
            executable: script, environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GH_FAKE_DIR": ghDir.path],
            timeout: 30)
        let parentBranch = "workbench/\(parent)"
        let childBranch = "workbench/\(child)"
        try await Self.build(
            self_: fx, parentBranch: parentBranch, childBranch: childBranch, conflict: conflict, mergeParent: mergeParent)
        tipA = try await git(["rev-parse", "refs/remotes/origin/\(parentBranch)"])
        tipB = try await git(["rev-parse", "refs/remotes/origin/\(childBranch)"])
        try writeThreads()
        try view(1, state: mergeParent ? "MERGED" : "OPEN", base: "main", head: tipA)
        try view(2, state: "OPEN", base: parentBranch, head: tipB)
    }

    private static func build(
        self_ fx: RunnerFixture, parentBranch: String, childBranch: String, conflict: Bool, mergeParent: Bool
    ) async throws {
        func run(_ args: [String]) async throws { _ = try await shipOut(args, fx.repo, fx) }
        func commit(_ file: String, _ text: String, _ message: String) async throws {
            try text.write(to: fx.repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try await run(["add", file])
            try await run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message])
        }
        try await run(["checkout", "-q", "-b", parentBranch])
        try await commit("a.txt", "from step one\n", "step one")
        try await run(["push", "-q", "origin", parentBranch])
        try await run(["checkout", "-q", "-b", childBranch])
        try await commit("b.txt", "from step two\n", "step two")
        try await run(["push", "-q", "origin", childBranch])
        try await run(["checkout", "-q", "main"])
        if mergeParent {
            // The squash merge: step one's content as a new commit on main (and, for a conflict, something on b.txt too).
            try await commit("a.txt", "from step one\n", "squash of step one")
            if conflict { try await commit("b.txt", "main wrote this instead\n", "someone else touched b.txt") }
            try await run(["push", "-q", "origin", "main"])
        }
        try await run(["fetch", "-q", "origin"])
    }

    func view(_ number: Int, state: String, base: String, head: String) throws {
        try #"{"state":"\#(state)","baseRefName":"\#(base)","headRefOid":"\#(head)"}"#
            .write(to: ghDir.appendingPathComponent("view_\(number)"), atomically: true, encoding: .utf8)
    }

    func writeThreads() throws {
        func log(_ thread: String, _ lines: [String]) throws {
            try FileManager.default.createDirectory(at: fx.project.threadDirectory(thread), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: fx.project.eventsURL(thread), atomically: true, encoding: .utf8)
        }
        func opened(_ seq: Int, _ number: Int) -> String {
            #"{"v":1,"seq":\#(seq),"ts":"2026-11-21T10:00:00.000Z","turn":0,"kind":"pr.opened","data":"#
                + #"{"number":\#(number),"url":"https://example.test/pull/\#(number)"}}"#
        }
        try log(parent, [opened(1, 1)])
        try log(
            child,
            [
                #"{"v":1,"seq":1,"ts":"2026-11-21T10:00:00.000Z","turn":0,"kind":"worktree.created","data":"#
                    + #"{"base_commit":"\#(tipA)"}}"#,
                opened(2, 2),
            ])
        let directory = fx.project.seriesDirectory("s")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "## 1\nproject: \(fx.repo.path)\ngoal: g.md\n## 2\nproject: \(fx.repo.path)\ngoal: g.md\nbase: after 1\n"
            .write(to: directory.appendingPathComponent("series.md"), atomically: true, encoding: .utf8)
        try """
            ---
            title: A goal
            budget_usd: 1.00
            turn_timeout_min: 10
            ---

            ## Request

            Do it.

            ## Criteria

            - [c1] Done.
              - proof: a test

            ## Out of scope

            - Nothing.
            """.write(to: directory.appendingPathComponent("g.md"), atomically: true, encoding: .utf8)
        let log1 = SeriesStepLog(project: fx.project, series: "s")
        try log1.append(SeriesRecord(step: 1, thread: parent, at: "t"))
        try log1.append(SeriesRecord(step: 2, thread: child, at: "t"))
    }

    func rebaser() -> SeriesRebaser { SeriesRebaser(library: library, git: fx.git, gh: gh) }

    func originTip(_ branch: String) async throws -> String {
        try await shipOut(["rev-parse", "refs/heads/\(branch)"], bare, fx)
    }

    func edited(_ number: Int) -> String? {
        (try? String(contentsOf: ghDir.appendingPathComponent("edit_\(number)"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func leftoverWorktrees() async throws -> [String] {
        let listed = try await git(["worktree", "list", "--porcelain"])
        return listed.split(separator: "\n").filter { $0.contains("series-rebase-") }.map(String.init)
    }
}

@Suite(.processGate) struct SeriesRebaseTests {
    @Test func aStepWhoseParentWasSquashMergedIsReplayedOntoTheBaseAndRetargeted() async throws {
        let s = try await Stack()
        let results = try await s.rebaser().run("s")
        #expect(results == [SeriesRebaseStep(step: 2, outcome: .rebased(pullRequest: 2, base: "main"))])
        // Exactly the step's own commit sits on main now, and the parent's commit is not replayed a second time.
        let log = try await s.git(["log", "--format=%s", "refs/heads/main..refs/heads/workbench/\(s.child)"], in: s.bare)
        #expect(log == "step two")
        let tree = try await s.git(["ls-tree", "--name-only", "refs/heads/workbench/\(s.child)"], in: s.bare)
        #expect(tree.contains("a.txt") && tree.contains("b.txt"))
        #expect(s.edited(2) == "main")
        #expect(try await s.leftoverWorktrees().isEmpty)
    }

    @Test func runningItAgainChangesNothing() async throws {
        let s = try await Stack()
        _ = try await s.rebaser().run("s")
        let tip = try await s.originTip("workbench/\(s.child)")
        let newHead = try await s.originTip("workbench/\(s.child)")
        try s.view(2, state: "OPEN", base: "main", head: newHead)
        let results = try await s.rebaser().run("s")
        #expect(results == [SeriesRebaseStep(step: 2, outcome: .alreadyDone)])
        #expect(try await s.originTip("workbench/\(s.child)") == tip)
    }

    @Test func aParentThatIsNotMergedYetLeavesEverythingAlone() async throws {
        let s = try await Stack(mergeParent: false)
        let before = try await s.originTip("workbench/\(s.child)")
        let results = try await s.rebaser().run("s")
        guard case .waiting(let why)? = results.first?.outcome else {
            Issue.record("expected waiting, got \(results)")
            return
        }
        #expect(why.contains("not merged"))
        #expect(try await s.originTip("workbench/\(s.child)") == before)
        #expect(s.edited(2) == nil)
    }

    @Test func aConflictIsListedAndNothingIsPushedOrRetargeted() async throws {
        let s = try await Stack(conflict: true)
        let before = try await s.originTip("workbench/\(s.child)")
        let results = try await s.rebaser().run("s")
        #expect(results == [SeriesRebaseStep(step: 2, outcome: .conflict(files: ["b.txt"]))])
        #expect(try await s.originTip("workbench/\(s.child)") == before)
        #expect(s.edited(2) == nil)
        #expect(try await s.leftoverWorktrees().isEmpty)
    }

    @Test func aBranchThatMovedSinceGitHubReportedItIsNotOverwritten() async throws {
        let s = try await Stack()
        // GitHub says the pull request is at an older commit than origin's branch: someone pushed in between.
        try s.view(2, state: "OPEN", base: "workbench/\(s.parent)", head: s.tipA)
        let before = try await s.originTip("workbench/\(s.child)")
        let results = try await s.rebaser().run("s")
        guard case .failed(let why)? = results.first?.outcome else {
            Issue.record("expected failed, got \(results)")
            return
        }
        #expect(why.contains("push was refused"))
        #expect(try await s.originTip("workbench/\(s.child)") == before)
        #expect(s.edited(2) == nil)
    }

    @Test func aClosedStepPullRequestIsReportedNotTouched() async throws {
        let s = try await Stack()
        try s.view(2, state: "CLOSED", base: "workbench/\(s.parent)", head: s.tipB)
        let results = try await s.rebaser().run("s")
        guard case .failed(let why)? = results.first?.outcome else {
            Issue.record("expected failed, got \(results)")
            return
        }
        #expect(why.contains("closed"))
    }

    @Test func aStepWithNoThreadYetWaitsAndAFirstStepIsLeftOut() async throws {
        let s = try await Stack()
        try FileManager.default.removeItem(at: SeriesStepLog(project: s.fx.project, series: "s").url)
        let results = try await s.rebaser().run("s")
        #expect(results.map(\.step) == [2])
        guard case .waiting? = results.first?.outcome else {
            Issue.record("expected waiting, got \(results)")
            return
        }
    }
}
