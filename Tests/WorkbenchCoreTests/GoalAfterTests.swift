import Foundation
import Testing

@testable import WorkbenchCore

private func fill(_ fx: RunnerFixture, _ id: String) throws {
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
}

@Suite(.processGate) struct GoalAfterTests {
    @Test func aGoalAfterAShippedThreadIsCutFromThatThreadsBranchOnOrigin() async throws {
        let shipped = try await reviewedPR()
        let fx = shipped.fx
        let child = try await fx.service.newThread(name: "child", after: shipped.id)

        let parsed = try GoalFile.parse(String(contentsOf: fx.project.goalURL(child), encoding: .utf8))
        #expect(parsed.goal.base == "origin/workbench/\(shipped.id)")
        #expect(parsed.goal.pushTo == nil)
        #expect(try fx.events(child).first { $0.kind == .threadCreated }?.data["after"]?.stringValue == shipped.id)

        try fill(fx, child)
        try await fx.service.approve(id: child)
        _ = try await fx.runner(child).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(child)
        let created = try fx.events(child).last { $0.kind == .worktreeCreated }
        #expect(created?.data["base_commit"]?.stringValue == shipped.head)
        #expect(try await shipOut(["merge-base", "--is-ancestor", shipped.head, "HEAD"], worktree, fx).isEmpty)
    }

    @Test func aParentThatNeverOpenedAPullRequestIsRefusedAndNothingIsCreated() async throws {
        let fx = try await RunnerFixture()
        _ = try await addOrigin(fx)
        let parent = try await fx.service.newThread(name: "parent")
        let before = try FileManager.default.contentsOfDirectory(atPath: fx.project.threadsDirectory.path).sorted()
        for name in [parent, "g-2020-01-01-nothing"] {
            do {
                _ = try await fx.service.newThread(name: "child", after: name)
                Issue.record("expected a refusal for \(name)")
            } catch let error as ThreadServiceError { #expect(error == .afterNotShipped(name)) }
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: fx.project.threadsDirectory.path).sorted()
        #expect(before == after)
    }

    @Test func afterTakesNeitherABaseNorAnUpdateTarget() async throws {
        let shipped = try await reviewedPR()
        for (base, updating) in [("main", nil), (nil, "feature/pr")] as [(String?, String?)] {
            do {
                _ = try await shipped.fx.service.newThread(name: "child", base: base, updating: updating, after: shipped.id)
                Issue.record("expected a refusal")
            } catch let error as ThreadServiceError { #expect(error == .afterWithBase) }
        }
    }

    @Test func aNameThatIsNotAThreadIdIsRefusedBeforeAnythingReachesGit() async throws {
        let fx = try await RunnerFixture()
        do {
            _ = try await fx.service.newThread(name: "child", after: "../x")
            Issue.record("expected a refusal")
        } catch let error as ThreadStoreError { #expect(error == .invalidName("../x")) }
    }

    @Test func aCommitPushedToTheParentBranchBeforeTheFirstRunIsPickedUp() async throws {
        let shipped = try await reviewedPR()
        let fx = shipped.fx
        let child = try await fx.service.newThread(name: "child", after: shipped.id)
        try fill(fx, child)
        try await fx.service.approve(id: child)

        let other = fx.repo.deletingLastPathComponent().appendingPathComponent("other-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", "-b", "workbench/\(shipped.id)", shipped.bare.path, other.path], in: fx.repo)
        try "later\n".write(to: other.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: other)
        _ = try await fx.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "review fix"], in: other)
        _ = try await fx.git.run(["push", "-q", "origin", "workbench/\(shipped.id)"], in: other)

        _ = try await fx.runner(child).run(fx.options())
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(child)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("later.txt").path))
    }

    @Test func aParentThatContinuedABranchStacksOnThatBranchNotItsOwn() async throws {
        let fx = try await RunnerFixture()
        _ = try await originWithBranch(fx)
        let id = try await approvedUpdateThread(fx)
        _ = try await fx.runner(id).run(fx.options())
        try "one\nhello\n".write(
            to: fx.project.worktreesDirectory.appendingPathComponent(id).appendingPathComponent("a.txt"), atomically: true,
            encoding: .utf8)
        try await fx.service.accept(id: id, message: "chore: update the pull request")
        let gh = try FakeGH(in: fx)
        let head = try await shipOut(["rev-parse", "HEAD"], fx.project.worktreesDirectory.appendingPathComponent(id), fx)
        try openPR(gh, head: head)
        _ = try await fx.service.shipPush(id: id, gh: gh.runner)
        _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)

        let child = try await fx.service.newThread(name: "child", after: id)
        let parsed = try GoalFile.parse(String(contentsOf: fx.project.goalURL(child), encoding: .utf8))
        #expect(parsed.goal.base == "origin/feature/pr")
        #expect(parsed.goal.stackedOn == "feature/pr")
    }
}
