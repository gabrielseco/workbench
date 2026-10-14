import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct StartAdvisoryTests {
    @Test func aBaseBehindOriginIsSaidOnceAndTheWorktreeIsStillCutFromTheLocalBase() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        let bare = fx.repo.deletingLastPathComponent().appendingPathComponent("o-\(UUID().uuidString).git")
        _ = try await fx.git.run(["init", "-q", "--bare", bare.path], in: fx.repo)
        _ = try await fx.git.run(["remote", "add", "origin", bare.path], in: fx.repo)
        _ = try await fx.git.run(["push", "-q", "origin", "main"], in: fx.repo)
        let clone = fx.repo.deletingLastPathComponent().appendingPathComponent("c-\(UUID().uuidString)")
        _ = try await fx.git.run(["clone", "-q", "-b", "main", bare.path, clone.path], in: fx.repo)
        try "x\n".write(to: clone.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: clone)
        _ = try await fx.git.run(["commit", "-q", "-m", "x"], in: clone)
        _ = try await fx.git.run(["push", "-q", "origin", "HEAD:main"], in: clone)
        let local = try await fx.git.run(["rev-parse", "main"], in: fx.repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let notices = NoticeBox()
        _ = try await fx.runner(id, notices: notices).run(fx.options())
        let advisories = notices.all.compactMap { notice -> String? in
            if case .advisory(let text) = notice { return text }
            return nil
        }
        #expect(advisories.count == 1 && advisories[0].contains("main is 1 commit behind origin/main"), "\(advisories)")
        let created = try #require(try fx.events(id).first { $0.kind == .worktreeCreated })
        #expect(created.data["base_commit"]?.stringValue == local)
    }

    @Test func localEditsAndABehindBaseAreSaidOnTheFirstTurnOnly() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try "local edit\n".write(to: fx.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let notices = NoticeBox()
        _ = try await fx.runner(id, notices: notices).run(fx.options())
        let advisories = notices.all.compactMap { notice -> String? in
            if case .advisory(let text) = notice { return text }
            return nil
        }
        #expect(advisories.count == 1, "\(advisories)")
        #expect(advisories.first?.contains("1 file changed in your checkout is not part of this thread") == true)
        #expect(try String(contentsOf: fx.repo.appendingPathComponent("a.txt"), encoding: .utf8) == "local edit\n")
        let worktree = fx.project.worktreesDirectory.appendingPathComponent(id)
        #expect(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8) != "local edit\n")
    }
}
