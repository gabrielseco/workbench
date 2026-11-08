import Foundation
import Testing

@testable import WorkbenchCore

/// A new goal brings the local base up to date with origin before its worktree is cut, and does not start when that cannot
/// be done without losing work or without reaching origin.
@Suite(.processGate) struct GoalStartTests {
    /// An origin that has the fixture's `main`, and a second clone of it to move origin's `main` with.
    private struct Origin {
        let bare: URL
        let clone: URL
        let git: GitRunner

        init(for fx: RunnerFixture) async throws {
            git = fx.git
            let dir = fx.repo.deletingLastPathComponent()
            bare = dir.appendingPathComponent("origin-\(UUID().uuidString).git")
            clone = dir.appendingPathComponent("clone-\(UUID().uuidString)")
            try await Self.must(git, ["init", "-q", "--bare", bare.path], in: fx.repo)
            try await Self.must(git, ["remote", "add", "origin", bare.path], in: fx.repo)
            try await Self.must(git, ["push", "-q", "origin", "main"], in: fx.repo)
            try await Self.must(git, ["clone", "-q", "-b", "main", bare.path, clone.path], in: fx.repo)
        }

        /// Commits `text` to `file` on origin's `main` and returns the new tip.
        @discardableResult
        func advance(_ file: String = "x.txt", _ text: String = "x\n") async throws -> String {
            try text.write(to: clone.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try await Self.must(git, ["add", "-A"], in: clone)
            try await Self.must(git, ["commit", "-q", "-m", "origin moves"], in: clone)
            try await Self.must(git, ["push", "-q", "origin", "HEAD:main"], in: clone)
            return try await head("HEAD", in: clone)
        }

        func head(_ ref: String, in dir: URL) async throws -> String {
            try await git.run(["rev-parse", ref], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func must(_ git: GitRunner, _ args: [String], in dir: URL) async throws {
            let result = try await git.run(args, in: dir)
            #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
        }
    }

    private func baseCommit(_ fx: RunnerFixture, _ id: String) throws -> String? {
        try fx.events(id).first { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue
    }

    /// The run is refused with `baseUpdateFailed`, and nothing started: no worktree, no turn.
    private func expectRefused(_ fx: RunnerFixture, _ id: String) async throws -> String {
        var message = ""
        do {
            _ = try await fx.runner(id).run(fx.options())
            Issue.record("the goal started")
        } catch let error as WorktreeError {
            guard case .baseUpdateFailed = error else { throw error }
            message = error.description
        }
        #expect(!FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.appendingPathComponent(id).path))
        #expect(try !fx.kinds(id).contains(EventKind.turnStarted.rawValue))
        #expect(try baseCommit(fx, id) == nil)
        return message
    }

    @Test func startsWorktreeFromUpdatedMain() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let origin = try await Origin(for: fx)
        let tip = try await origin.advance()

        let notices = NoticeBox()
        _ = try await fx.runner(id, notices: notices).run(fx.options())

        #expect(try baseCommit(fx, id) == tip)
        #expect(try await origin.head("refs/heads/main", in: fx.repo) == tip, "the local main was brought forward")
        // `main` is checked out in the project's checkout, so its files moved with it.
        #expect(FileManager.default.fileExists(atPath: fx.repo.appendingPathComponent("x.txt").path))
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("x.txt").path))
        let behind = notices.all.contains { if case .advisory(let text) = $0 { text.contains("behind") } else { false } }
        #expect(!behind, "an up-to-date base is not reported as behind")
    }

    @Test func startsWhenMainIsCurrent() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let origin = try await Origin(for: fx)
        let local = try await origin.head("refs/heads/main", in: fx.repo)

        let report = try await fx.runner(id).run(fx.options())

        #expect(report.result == .succeeded)
        #expect(try baseCommit(fx, id) == local)
        #expect(try await origin.head("refs/heads/main", in: fx.repo) == local)
    }

    @Test func startsWhenTheRepositoryHasNoOrigin() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let report = try await fx.runner(id).run(fx.options())
        #expect(report.result == .succeeded)
    }

    @Test func stopsWhenMainUpdateFails() async throws {
        // Origin cannot be reached.
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let origin = try await Origin(for: fx)
        let gone = fx.repo.deletingLastPathComponent().appendingPathComponent("gone-\(UUID().uuidString).git")
        try await Origin.must(fx.git, ["remote", "set-url", "origin", gone.path], in: fx.repo)
        let unreachable = try await expectRefused(fx, id)
        #expect(unreachable.contains("main"), "\(unreachable)")
        _ = origin

        // A run after origin is back starts.
        try await Origin.must(fx.git, ["remote", "set-url", "origin", origin.bare.path], in: fx.repo)
        let tip = try await origin.advance()
        _ = try await fx.runner(id).run(fx.options())
        #expect(try baseCommit(fx, id) == tip)
    }

    @Test func stopsWhenMainHasDivergedFromOrigin() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let origin = try await Origin(for: fx)
        let remoteTip = try await origin.advance()
        try "mine\n".write(to: fx.repo.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try await Origin.must(fx.git, ["add", "mine.txt"], in: fx.repo)
        try await Origin.must(fx.git, ["commit", "-q", "-m", "local work"], in: fx.repo)
        let localTip = try await origin.head("refs/heads/main", in: fx.repo)

        _ = try await expectRefused(fx, id)

        #expect(try await origin.head("refs/heads/main", in: fx.repo) == localTip, "the local commit is kept")
        #expect(try await origin.head("refs/remotes/origin/main", in: fx.repo) == remoteTip)
    }

    @Test func preservesLocalWorkWhenUpdatingMain() async throws {
        // An uncommitted edit the update does not touch is kept, and the goal starts from origin's tip.
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let origin = try await Origin(for: fx)
        let tip = try await origin.advance()
        try "local edit\n".write(to: fx.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.runner(id).run(fx.options())
        #expect(try baseCommit(fx, id) == tip)
        #expect(try String(contentsOf: fx.repo.appendingPathComponent("a.txt"), encoding: .utf8) == "local edit\n")

        // An uncommitted edit the update would overwrite stops the goal, and stays as it was.
        let other = try await RunnerFixture()
        let otherID = try await other.approvedThread()
        let otherOrigin = try await Origin(for: other)
        let before = try await otherOrigin.head("refs/heads/main", in: other.repo)
        try await otherOrigin.advance("a.txt", "theirs\n")
        try "mine\n".write(to: other.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await expectRefused(other, otherID)
        #expect(try String(contentsOf: other.repo.appendingPathComponent("a.txt"), encoding: .utf8) == "mine\n")
        #expect(try await otherOrigin.head("refs/heads/main", in: other.repo) == before)

        // Local commits origin does not have, with nothing new on origin: kept, and the goal starts from them.
        let ahead = try await RunnerFixture()
        let aheadID = try await ahead.approvedThread()
        let aheadOrigin = try await Origin(for: ahead)
        try "mine\n".write(to: ahead.repo.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        try await Origin.must(ahead.git, ["add", "mine.txt"], in: ahead.repo)
        try await Origin.must(ahead.git, ["commit", "-q", "-m", "local work"], in: ahead.repo)
        let localTip = try await aheadOrigin.head("refs/heads/main", in: ahead.repo)
        _ = try await ahead.runner(aheadID).run(ahead.options())
        #expect(try baseCommit(ahead, aheadID) == localTip)
        #expect(try await aheadOrigin.head("refs/heads/main", in: ahead.repo) == localTip)
    }

    @Test func movesMainByRefWhenNoCheckoutHasIt() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let origin = try await Origin(for: fx)
        try await Origin.must(fx.git, ["checkout", "-q", "-b", "elsewhere"], in: fx.repo)
        let tip = try await origin.advance()
        _ = try await fx.runner(id).run(fx.options())
        #expect(try baseCommit(fx, id) == tip)
        #expect(try await origin.head("refs/heads/main", in: fx.repo) == tip)
        #expect(try await origin.head("HEAD", in: fx.repo) != tip, "the checkout on another branch was left alone")
    }

    @Test func stopsRatherThanOverwriteAnIgnoredFile() async throws {
        // Origin starts tracking a path the checkout has as an ignored file: git must not replace it.
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try "secret.txt\n".write(to: fx.repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try await Origin.must(fx.git, ["add", ".gitignore"], in: fx.repo)
        try await Origin.must(fx.git, ["commit", "-q", "-m", "ignore secret"], in: fx.repo)
        let origin = try await Origin(for: fx)
        let before = try await origin.head("refs/heads/main", in: fx.repo)
        try "theirs\n".write(to: origin.clone.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try await Origin.must(fx.git, ["add", "-f", "secret.txt"], in: origin.clone)
        try await Origin.must(fx.git, ["commit", "-q", "-m", "track secret"], in: origin.clone)
        try await Origin.must(fx.git, ["push", "-q", "origin", "HEAD:main"], in: origin.clone)
        try "mine\n".write(to: fx.repo.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        _ = try await expectRefused(fx, id)

        #expect(try String(contentsOf: fx.repo.appendingPathComponent("secret.txt"), encoding: .utf8) == "mine\n")
        #expect(try await origin.head("refs/heads/main", in: fx.repo) == before)
    }

    @Test func stopsOnAnOverlappingEditEvenWithAutoStash() async throws {
        // With `merge.autoStash`, git could stash the edit, move main and leave conflicts while reporting success.
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let origin = try await Origin(for: fx)
        try await Origin.must(fx.git, ["config", "merge.autoStash", "true"], in: fx.repo)
        let before = try await origin.head("refs/heads/main", in: fx.repo)
        try await origin.advance("a.txt", "theirs\n")
        try "mine\n".write(to: fx.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        _ = try await expectRefused(fx, id)

        #expect(try String(contentsOf: fx.repo.appendingPathComponent("a.txt"), encoding: .utf8) == "mine\n")
        #expect(try await origin.head("refs/heads/main", in: fx.repo) == before)
        let stashes = try await fx.git.run(["stash", "list"], in: fx.repo).stdout
        #expect(stashes.isEmpty, "nothing was stashed: \(stashes)")
    }

    @Test func asksOriginWhenNothingCachedSaysItHasTheBase() async throws {
        // Origin was added to an existing repository and never fetched: its main may already be ahead.
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let origin = try await Origin(for: fx)
        let tip = try await origin.advance()
        try await Origin.must(fx.git, ["update-ref", "-d", "refs/remotes/origin/main"], in: fx.repo)
        _ = try await fx.runner(id).run(fx.options())
        #expect(try baseCommit(fx, id) == tip)

        // The same, with origin unreachable: not taken for a local-only branch.
        let offline = try await RunnerFixture()
        let offlineID = try await offline.approvedThread()
        let gone = offline.repo.deletingLastPathComponent().appendingPathComponent("gone-\(UUID().uuidString).git")
        try await Origin.must(offline.git, ["remote", "add", "origin", gone.path], in: offline.repo)
        _ = try await expectRefused(offline, offlineID)

        // Origin answers and has no such branch: a local-only base starts as it is.
        let local = try await RunnerFixture()
        let localID = try await local.approvedThread()
        let empty = local.repo.deletingLastPathComponent().appendingPathComponent("empty-\(UUID().uuidString).git")
        try await Origin.must(local.git, ["init", "-q", "--bare", empty.path], in: local.repo)
        try await Origin.must(local.git, ["remote", "add", "origin", empty.path], in: local.repo)
        let report = try await local.runner(localID).run(local.options())
        #expect(report.result == .succeeded)
    }

    /// A thread approved for a handoff: an interactive session cannot enforce a dollar cap, so the goal has none.
    private func handoffThread(_ fx: RunnerFixture) async throws -> String {
        let id = try await fx.approvedThread()
        let url = fx.project.goalURL(id)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("budget_usd:") ? "spend_policy: timeout_only" : String($0) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    @Test func aHandoffStartsFromUpdatedMainAndStopsWhenItCannot() async throws {
        let fx = try await RunnerFixture()
        let id = try await handoffThread(fx)
        let origin = try await Origin(for: fx)
        let tip = try await origin.advance()
        let service = ThreadService(project: fx.project, git: fx.git)
        _ = try await service.prepareHandoff(id: id)
        #expect(try baseCommit(fx, id) == tip)
        #expect(try await origin.head("refs/heads/main", in: fx.repo) == tip)

        // Origin unreachable: nothing is cut.
        let offline = try await RunnerFixture()
        let offlineID = try await handoffThread(offline)
        let offlineOrigin = try await Origin(for: offline)
        try await offlineOrigin.advance()
        let gone = offline.repo.deletingLastPathComponent().appendingPathComponent("gone-\(UUID().uuidString).git")
        try await Origin.must(offline.git, ["remote", "set-url", "origin", gone.path], in: offline.repo)
        do {
            _ = try await ThreadService(project: offline.project, git: offline.git).prepareHandoff(id: offlineID)
            Issue.record("the goal was handed off")
        } catch let error as WorktreeError {
            guard case .baseUpdateFailed = error else { throw error }
        }
        #expect(!FileManager.default.fileExists(
            atPath: offline.project.worktreesDirectory.appendingPathComponent(offlineID).path))
        #expect(try baseCommit(offline, offlineID) == nil)
    }
}
