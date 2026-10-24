import Foundation
import Testing

@testable import WorkbenchCore

private func cli(_ arguments: [String], in fx: RunnerFixture) async throws -> (code: Int32?, text: String) {
    var spawn = SpawnRequest(
        executable: WorkbenchBinary.executable, arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName()],
        workingDirectory: fx.repo, timeout: 60)
    spawn.snapshotInterval = 3600
    let run = try ProcessRunner.start(spawn)
    var lines: [String] = []
    var code: Int32?
    for await event in run.events {
        if case .line(let line) = event { lines.append(line) }
        if case .exited(let e) = event, case .exited(let c) = e.termination { code = c }
    }
    return (code, lines.joined(separator: "\n"))
}

/// A scratch repository whose first branch is `branch`, with one commit unless `unborn`.
private func repo(on branch: String, unborn: Bool = false) async throws -> (URL, GitRunner) {
    let dir = Scratch.url("base")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let root = dir.resolvingSymlinksInPath()
    let git = try isolatedGit()
    _ = try await git.run(["init", "-q", "-b", branch], in: root)
    if !unborn { _ = try await git.run(["commit", "-q", "--allow-empty", "-m", "first"], in: root) }
    return (root, git)
}

private func defaultBase(_ root: URL, _ git: GitRunner) async -> String {
    await ThreadService(project: Project(root: root), git: git).defaultBase()
}

@Suite(.processGate) struct DefaultBaseTests {
    @Test func originHeadWinsOverALocalMainAndTheCheckedOutBranch() async throws {
        let (root, git) = try await repo(on: "main")
        _ = try await git.run(["update-ref", "refs/remotes/origin/master", "HEAD"], in: root)
        _ = try await git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"], in: root)
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: root)
        #expect(await defaultBase(root, git) == "master")
    }

    @Test func withoutOriginHeadALocalMainIsTheBase() async throws {
        let (root, git) = try await repo(on: "main")
        _ = try await git.run(["branch", "master"], in: root)
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: root)
        #expect(await defaultBase(root, git) == "main")
    }

    @Test func withOnlyTheOlderDefaultNameThatIsTheBase() async throws {
        let (root, git) = try await repo(on: "master")
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: root)
        #expect(await defaultBase(root, git) == "master")
    }

    @Test func withNeitherTheCheckedOutBranchIsTheBase() async throws {
        let (root, git) = try await repo(on: "trunk")
        _ = try await git.run(["checkout", "-q", "-b", "feature"], in: root)
        #expect(await defaultBase(root, git) == "feature")
    }

    @Test func anUnbornRepoGivesMain() async throws {
        let (root, git) = try await repo(on: "feature", unborn: true)
        #expect(await defaultBase(root, git) == "main")
    }

    @Test func goalNewUsesTheDefaultBranchAndSaysSo() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.git.run(["checkout", "-q", "-b", "feature"], in: fx.repo)
        let result = try await cli(["goal", "new", "plain"], in: fx)
        #expect(result.code == 0, "\(result.text)")
        #expect(result.text.contains("base:    main"))
        let id = try #require(ThreadStore(project: fx.project).threadIDs().first)
        #expect(try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8)).goal.base == "main")
    }

    @Test func aGivenBaseAlwaysWins() async throws {
        let fx = try await RunnerFixture()
        _ = try await fx.git.run(["checkout", "-q", "-b", "feature"], in: fx.repo)
        let result = try await cli(["goal", "new", "given", "--base", "feature"], in: fx)
        #expect(result.code == 0, "\(result.text)")
        #expect(result.text.contains("base:    feature"))
        let id = try #require(ThreadStore(project: fx.project).threadIDs().first)
        #expect(try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8)).goal.base == "feature")
    }
}
