import Foundation
import Testing

@testable import WorkbenchCore

private func goal(base: String = "origin/feature/pr", pushTo: String? = "feature/pr") -> String {
    let line = pushTo.map { "push_to: \($0)\n" } ?? ""
    return """
        ---
        id: g-2026-10-15-update
        title: Update a PR
        base: \(base)
        \(line)budget_usd: 5.00
        turn_timeout_min: 30
        ---

        ## Request

        Do the thing.

        ## Criteria

        - [c1] The thing is done.
          - proof: cat thing

        ## Out of scope

        - Everything else.
        """
}

private func problems(in text: String) -> [GoalProblem] {
    do { _ = try GoalFile.parse(text) } catch let error as GoalParseError { return error.problems } catch {}
    return []
}

@Suite struct GoalPushToParsingTests {
    @Test func thePushTargetIsReadAndIsOptional() throws {
        #expect(try GoalFile.parse(goal()).goal.pushTo == "feature/pr")
        #expect(try GoalFile.parse(goal(base: "main", pushTo: nil)).goal.pushTo == nil)
    }

    @Test func aMainlineBranchIsNotAPushTarget() {
        for bad in ["main", "master", "trunk", "develop", "Main", "-x", "a b", "a..b"] {
            let found = problems(in: goal(base: "origin/\(bad)", pushTo: bad))
            #expect(
                found.contains { $0.code == .invalidValue && $0.message.contains("'push_to'") }, "\(bad)")
        }
    }

    @Test func theBaseMustBeTheRemoteBranchItPushesTo() {
        let found = problems(in: goal(base: "main", pushTo: "feature/pr"))
        #expect(found.contains { $0.code == .invalidValue && $0.line == 4 && $0.message.contains("origin/feature/pr") })
    }

    @Test func approvalBindsThePushTarget() throws {
        let a = try GoalFile.parse(goal()).goal.contentHash
        let b = try GoalFile.parse(goal(base: "origin/other", pushTo: "other")).goal.contentHash
        #expect(a != b)
    }

    @Test func aDuplicatePushToKeyIsAnError() {
        let text = goal().replacingOccurrences(of: "push_to: feature/pr\n", with: "push_to: feature/pr\npush_to: feature/pr\n")
        #expect(problems(in: text).contains { $0.code == .duplicateKey })
    }
}

/// A branch with one commit on a bare `origin`, and no local copy of it.
private func originWithBranch(_ fx: RunnerFixture, _ branch: String = "feature/pr") async throws -> URL {
    let bare = try await addOrigin(fx)
    let scratch = fx.repo.deletingLastPathComponent().appendingPathComponent("pr-\(UUID().uuidString)")
    _ = try await fx.git.run(["worktree", "add", "-q", "-b", branch, scratch.path, "main"], in: fx.repo)
    try "pr work\n".write(to: scratch.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    _ = try await fx.git.run(["add", "b.txt"], in: scratch)
    _ = try await fx.git.run(["commit", "-q", "-m", "pr work"], in: scratch)
    _ = try await fx.git.run(["push", "-q", "origin", branch], in: scratch)
    _ = try await fx.git.run(["worktree", "remove", "--force", scratch.path], in: fx.repo)
    _ = try await fx.git.run(["branch", "-q", "-D", branch], in: fx.repo)
    return bare
}

private func approvedUpdateThread(_ fx: RunnerFixture, branch: String = "feature/pr") async throws -> String {
    let id = try await fx.service.newThread(name: "update", updating: branch)
    let url = fx.project.goalURL(id)
    var text = try String(contentsOf: url, encoding: .utf8)
    let fills = [
        ("TODO(workbench): say what should change, in a few sentences.", "Add a greeting to a.txt."),
        ("TODO(workbench): something that can be checked.", "a.txt contains the word hello."),
        ("TODO(workbench): how it will be shown (a test, a command, a screenshot).", "cat a.txt"),
        ("TODO(workbench): what must not change.", "Do not touch other files."),
    ]
    for (placeholder, value) in fills { text = text.replacingOccurrences(of: placeholder, with: value) }
    try text.write(to: url, atomically: true, encoding: .utf8)
    try await fx.service.approve(id: id)
    return id
}

@Suite struct UpdateThreadTests {
    @Test func updatingABranchSetsTheBaseAndThePushTarget() async throws {
        let fx = try await RunnerFixture()
        _ = try await originWithBranch(fx)
        let id = try await fx.service.newThread(name: "update", updating: "feature/pr")
        let parsed = try GoalFile.parse(String(contentsOf: fx.project.goalURL(id), encoding: .utf8))
        #expect(parsed.goal.base == "origin/feature/pr")
        #expect(parsed.goal.pushTo == "feature/pr")
    }

    @Test func aBranchOriginDoesNotHaveCreatesNothing() async throws {
        let fx = try await RunnerFixture()
        _ = try await addOrigin(fx)
        do {
            _ = try await fx.service.newThread(name: "update", updating: "feature/missing")
            Issue.record("expected a refusal")
        } catch let error as WorktreeError {
            guard case .remoteBranchUnavailable(let branch, _) = error else {
                Issue.record("got \(error)")
                return
            }
            #expect(branch == "feature/missing")
        }
        let threads = (try? FileManager.default.contentsOfDirectory(atPath: fx.project.threadsDirectory.path)) ?? []
        #expect(threads.isEmpty)
    }

    @Test func aMainlineBranchOrABaseAsWellIsRefused() async throws {
        let fx = try await RunnerFixture()
        _ = try await originWithBranch(fx)
        do {
            _ = try await fx.service.newThread(name: "update", updating: "main")
            Issue.record("expected a refusal")
        } catch let error as ThreadServiceError { #expect(error == .invalidPushTarget("main")) }
        do {
            _ = try await fx.service.newThread(name: "update", base: "main", updating: "feature/pr")
            Issue.record("expected a refusal")
        } catch let error as ThreadServiceError { #expect(error == .updateWithBase) }
    }

    @Test func theWorktreeIsCutFromTheBranchTipOnOriginEvenWithoutALocalCopy() async throws {
        let fx = try await RunnerFixture()
        _ = try await originWithBranch(fx)
        let id = try await approvedUpdateThread(fx)
        _ = try await fx.runner(id).run(fx.options())

        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("b.txt").path))
        let tip = try await shipOut(["rev-parse", "refs/remotes/origin/feature/pr"], fx.repo, fx)
        let created = try fx.events(id).last { $0.kind == .worktreeCreated }
        #expect(created?.data["base_commit"]?.stringValue == tip)
        #expect(created?.data["branch"]?.stringValue == "workbench/\(id)")
    }

    @Test func aCommitPushedToTheBranchBeforeTheFirstRunIsPickedUp() async throws {
        let fx = try await RunnerFixture()
        let bare = try await originWithBranch(fx)
        let id = try await approvedUpdateThread(fx)

        let other = fx.repo.deletingLastPathComponent().appendingPathComponent("other-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", "-b", "feature/pr", bare.path, other.path], in: fx.repo)
        try "later\n".write(to: other.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: other)
        _ = try await fx.git.run(["commit", "-q", "-m", "later"], in: other)
        _ = try await fx.git.run(["push", "-q", "origin", "feature/pr"], in: other)
        let newest = try await shipOut(["rev-parse", "HEAD"], other, fx)

        _ = try await fx.runner(id).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(try await shipOut(["rev-parse", "HEAD"], worktree, fx) == newest)
    }

    @Test func aBranchThatDisappearedFromOriginStopsTheRunBeforeAWorktreeExists() async throws {
        let fx = try await RunnerFixture()
        let bare = try await originWithBranch(fx)
        let id = try await approvedUpdateThread(fx)
        _ = try await fx.git.run(["branch", "-q", "-D", "feature/pr"], in: bare)

        do {
            _ = try await fx.runner(id).run(fx.options())
            Issue.record("expected the run to refuse")
        } catch let error as WorktreeError {
            guard case .remoteBranchUnavailable = error else {
                Issue.record("got \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fx.project.worktreesDirectory.appendingPathComponent(id).path))
        #expect(!(try fx.kinds(id)).contains("turn.started"))
    }
}
