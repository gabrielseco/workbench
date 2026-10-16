import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct DisposablePathsTests {
    @Test func onlyIgnoredPathsInsideADisposableEntryAreLetThrough() {
        let status = """
            !! node_modules/
            !! .next-mock/cache/
            !! notes.cache
            ?? loose.txt
             M a.txt
            !! node_modules-extra/
            """
        let blocking = ThreadService.blockingStatus(status, disposable: ["node_modules", ".next-mock"])
        #expect(blocking == ["!! notes.cache", "?? loose.txt", " M a.txt", "!! node_modules-extra/"])
        #expect(ThreadService.blockingStatus("!! node_modules/\n", disposable: []) == ["!! node_modules/"])
        #expect(ThreadService.blockingStatus("!! \"odd name\"\n", disposable: ["odd name"]).count == 1)
    }

    @Test func aStatusThatMayHaveBeenCutShortBlocksRemoval() {
        // Every retained line is disposable; what the cut dropped could be anything.
        let line = "!! node_modules/some/deep/path/file.js\n"
        let long = String(repeating: line, count: GitRunner.outputLimit / line.utf8.count + 1)
        #expect(long.utf8.count >= GitRunner.outputLimit)
        #expect(ThreadService.blockingStatus(long, disposable: ["node_modules"]).count == 1)
        #expect(ThreadService.blockingStatus(line, disposable: ["node_modules"]).isEmpty, "a short one still passes")
    }

    @Test func theKeyIsParsedAndMustStayInsideTheWorktree() throws {
        let base = "[tools]\navailable = [\"Read\"]\n"
        let config = try Config.parse("disposable_paths = [\"node_modules\", \".cache/build/\"]\n" + base)
        #expect(config.disposablePaths == ["node_modules", ".cache/build"])
        #expect(try Config.parse(base).disposablePaths.isEmpty)
        for bad in ["/etc", "../x", "a/../b", "", ".", "./.", "./.git", "a/./b", ".git", ".git/hooks", "a//b"] {
            #expect(throws: ConfigError.self, "\(bad)") {
                try Config.parse("disposable_paths = [\"\(bad)\"]\n" + base)
            }
        }
    }

    private func shipped(_ fx: RunnerFixture, _ gh: FakeGH) async throws -> (id: String, worktree: URL) {
        let (id, worktree) = try await acceptedThread(fx)
        _ = try await addOrigin(fx)
        _ = try await fx.service.shipPush(id: id, gh: gh.runner)
        _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
        return (id, worktree)
    }

    private func ignore(_ patterns: String, in worktree: URL, _ fx: RunnerFixture) async throws {
        let exclude = try await shipOut(["rev-parse", "--git-path", "info/exclude"], worktree, fx)
        let url = exclude.hasPrefix("/") ? URL(fileURLWithPath: exclude) : worktree.appendingPathComponent(exclude)
        try patterns.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func aWorktreeWithOnlyDisposableLeftoversIsRemovedAndAnyOtherIgnoredFileKeepsIt() async throws {
        let fx = try await RunnerFixture(extraConfig: "disposable_paths = [\"node_modules\", \".cache/build\"]")
        let gh = try FakeGH(in: fx)
        let (id, worktree) = try await shipped(fx, gh)
        try await ignore("node_modules/\n.cache/\n*.keep\n", in: worktree, fx)
        let fm = FileManager.default
        try fm.createDirectory(at: worktree.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try "x".write(to: worktree.appendingPathComponent("node_modules/pkg/i.js"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: worktree.appendingPathComponent(".cache/build"), withIntermediateDirectories: true)
        try "x".write(to: worktree.appendingPathComponent(".cache/build/o"), atomically: true, encoding: .utf8)
        try "mine".write(to: worktree.appendingPathComponent("a.keep"), atomically: true, encoding: .utf8)

        let kept = await fx.service.cleanShipped(id: id, gh: gh.runner)
        guard case .kept(let why) = kept else {
            Issue.record("expected kept, got \(kept)")
            return
        }
        #expect(why.contains("a.keep"), "\(why)")
        #expect(fm.fileExists(atPath: worktree.path))

        try fm.removeItem(at: worktree.appendingPathComponent("a.keep"))
        #expect(await fx.service.cleanShipped(id: id, gh: gh.runner) == .removed(path: worktree.path))
        #expect(!fm.fileExists(atPath: worktree.path))
    }

    @Test func withNoDisposablePathsAnIgnoredDirectoryStillKeepsTheWorktree() async throws {
        let fx = try await RunnerFixture()
        let gh = try FakeGH(in: fx)
        let (id, worktree) = try await shipped(fx, gh)
        try await ignore("node_modules/\n", in: worktree, fx)
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "x".write(to: worktree.appendingPathComponent("node_modules/i.js"), atomically: true, encoding: .utf8)
        guard case .kept = await fx.service.cleanShipped(id: id, gh: gh.runner) else {
            Issue.record("an ignored directory nobody declared disposable must keep the worktree")
            return
        }
    }
}
