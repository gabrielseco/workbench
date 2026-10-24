import Foundation
import Testing

@testable import WorkbenchCore

/// `baseGap(fetch: false)`: what a read-only command says without asking origin.
@Suite(.processGate) struct BaseGapTests {
    @Test func withoutAFetchTheGapUsesTheKnownOriginRefAndSaysHowOldItIs() async throws {
        let repo = try await TestRepo()
        let bare = repo.root.deletingLastPathComponent().appendingPathComponent("n-\(UUID().uuidString).git")
        _ = try await repo.git.run(["init", "-q", "--bare", bare.path], in: repo.root)
        try await repo.run("remote", "add", "origin", bare.path)
        try await repo.run("push", "-q", "origin", "main")
        let clone = repo.root.deletingLastPathComponent().appendingPathComponent("c-\(UUID().uuidString)")
        _ = try await repo.git.run(["clone", "-q", "-b", "main", bare.path, clone.path], in: repo.root)
        try "1\n".write(to: clone.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        _ = try await repo.git.run(["add", "-A"], in: clone)
        _ = try await repo.git.run(["commit", "-q", "-m", "n"], in: clone)
        _ = try await repo.git.run(["push", "-q", "origin", "HEAD:main"], in: clone)
        let known = try await repo.head("origin/main")
        // Origin moved, but this repository has not been told: the answer is "not behind", and git was not asked.
        let quiet = await repo.manager.baseGap(base: "main", fetch: false)
        #expect(quiet?.behind == 0 && quiet?.fetchNote == nil, "\(String(describing: quiet))")
        #expect(try await repo.head("origin/main") == known, "nothing was fetched")
        #expect(quiet?.knownFrom == .unknown, "this repository never fetched, so it cannot say how old that is")
        let fetched = await repo.manager.baseGap(base: "main")
        #expect(fetched == WorktreeManager.BaseGap(base: "main", behind: 1, fetchNote: nil))
        let again = await repo.manager.baseGap(base: "main", fetch: false)
        #expect(again?.behind == 1, "after a fetch, the known ref says it")
        if case .lastFetch(let date)? = again?.knownFrom {
            #expect(Date().timeIntervalSince(date) < 60, "FETCH_HEAD was just rewritten")
        } else {
            Issue.record("expected a last-fetch time: \(String(describing: again))")
        }
    }

    @Test func aLaterFetchOfAnotherBranchLeavesTheAgeUnknownNotFresh() async throws {
        let repo = try await TestRepo()
        let bare = repo.root.deletingLastPathComponent().appendingPathComponent("a-\(UUID().uuidString).git")
        _ = try await repo.git.run(["init", "-q", "--bare", bare.path], in: repo.root)
        try await repo.run("remote", "add", "origin", bare.path)
        try await repo.run("push", "-q", "origin", "main")
        try await repo.run("push", "-q", "origin", "main:other")
        _ = await repo.manager.baseGap(base: "main")
        if case .lastFetch? = await repo.manager.baseGap(base: "main", fetch: false)?.knownFrom {} else {
            Issue.record("a fetch of main dates origin/main")
        }
        // Days later someone fetches only `other`: FETCH_HEAD is rewritten, but origin/main is no fresher.
        try await repo.run("fetch", "-q", "--no-tags", "origin", "+refs/heads/other:refs/remotes/origin/other")
        #expect(await repo.manager.baseGap(base: "main", fetch: false)?.knownFrom == .unknown)

        // Another remote that also has a main does not date origin's.
        let elsewhere = repo.root.deletingLastPathComponent().appendingPathComponent("e-\(UUID().uuidString).git")
        _ = try await repo.git.run(["clone", "-q", "--bare", bare.path, elsewhere.path], in: repo.root)
        try await repo.run("remote", "add", "elsewhere", elsewhere.path)
        _ = await repo.manager.baseGap(base: "main")
        try await repo.run("fetch", "-q", "--no-tags", "elsewhere", "+refs/heads/main:refs/remotes/elsewhere/main")
        #expect(await repo.manager.baseGap(base: "main", fetch: false)?.knownFrom == .unknown)
    }

    @Test func anAppendedFetchThatKeptAnOlderEntryLeavesTheAgeUnknown() async throws {
        let repo = try await TestRepo()
        let bare = repo.root.deletingLastPathComponent().appendingPathComponent("p-\(UUID().uuidString).git")
        _ = try await repo.git.run(["init", "-q", "--bare", bare.path], in: repo.root)
        try await repo.run("remote", "add", "origin", bare.path)
        try await repo.run("push", "-q", "origin", "main")
        try await repo.run("push", "-q", "origin", "main:other")
        _ = await repo.manager.baseGap(base: "main")
        // `--append` keeps main's old entry in FETCH_HEAD and moves the file's mtime.
        try await repo.run("fetch", "-q", "--no-tags", "--append", "origin", "+refs/heads/other:refs/remotes/origin/other")
        #expect(await repo.manager.baseGap(base: "main", fetch: false)?.knownFrom == .unknown)

        // A plain `git fetch` of everything dates main again.
        try await repo.run("fetch", "-q", "--no-tags", "origin")
        if case .lastFetch? = await repo.manager.baseGap(base: "main", fetch: false)?.knownFrom {} else {
            Issue.record("a plain fetch dates origin/main")
        }
    }
}
