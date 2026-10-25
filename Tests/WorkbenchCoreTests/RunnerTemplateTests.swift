import Foundation
import Testing

@testable import WorkbenchCore

@Suite(.processGate) struct RunnerTemplateTests {
    @Test func aFixtureStartsOnMainWithOneCommitAndACleanTree() async throws {
        let fx = try await RunnerFixture()
        let branch = try await fx.git.run(["symbolic-ref", "--short", "HEAD"], in: fx.repo).stdout
        #expect(branch.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
        let log = try await fx.git.run(["log", "--format=%s"], in: fx.repo).stdout
        #expect(log.trimmingCharacters(in: .whitespacesAndNewlines) == "first")
        #expect(try String(contentsOf: fx.repo.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        // Only the config a fixture writes itself is untracked; nothing else came with the copy.
        let status = try await fx.git.run(["status", "--porcelain"], in: fx.repo).stdout
        #expect(status.trimmingCharacters(in: .whitespacesAndNewlines) == "?? .workbench/")
    }

    @Test func twoFixturesDoNotShareAnything() async throws {
        let first = try await RunnerFixture()
        let second = try await RunnerFixture()
        #expect(first.repo != second.repo)
        try "changed\n".write(to: first.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await first.git.run(["commit", "-qam", "only in the first"], in: first.repo)

        #expect(try String(contentsOf: second.repo.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        let log = try await second.git.run(["log", "--format=%s"], in: second.repo).stdout
        #expect(log.trimmingCharacters(in: .whitespacesAndNewlines) == "first")
    }

    @Test func theTemplateIsBuiltOnceHoweverManyFixturesAskAtTheSameTime() async throws {
        let git = try isolatedGit()
        let asked = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 { group.addTask { try await RunnerTemplate.repository(git: git) } }
            return try await group.reduce(into: Set<URL>()) { $0.insert($1) }
        }
        #expect(asked.count == 1, "\(asked)")
        #expect(try await RunnerTemplate.repository(git: git) == asked.first)
    }

    @Test func noGitMaintenanceRunsInATemplateCopyOrLeavesALockBehind() async throws {
        let fx = try await RunnerFixture()
        for (key, expected) in [("maintenance.auto", "false"), ("gc.auto", "0")] {
            let value = try await fx.git.run(["config", "--get", key], in: fx.repo).stdout
            #expect(value.trimmingCharacters(in: .whitespacesAndNewlines) == expected, "\(key)")
        }
        // The race this prevents: a lock file present while the template is copied.
        let template = try await RunnerTemplate.repository(git: fx.git)
        let git = template.appendingPathComponent("repo/.git")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: git.path)) ?? []
        #expect(!names.contains { $0.hasSuffix(".lock") || $0 == "gc.pid" }, "\(names)")
    }

    @Test func aFixtureKeepsItsOwnConfig() async throws {
        let plain = try await RunnerFixture()
        let custom = try await RunnerFixture(extraConfig: "check_command = \"true\"")
        #expect(try String(contentsOf: custom.project.configURL, encoding: .utf8).contains("check_command"))
        #expect(!(try String(contentsOf: plain.project.configURL, encoding: .utf8)).contains("check_command"))
    }
}
