import Foundation
import Testing

@testable import WorkbenchCore

// MARK: scripts/check-changed.sh --plan, in a throwaway git repo

@Suite struct CheckChangedTests {
    private struct Repo {
        let dir: URL

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("wb-changed-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scripts/check-changed.sh")
            try write("scripts/check-changed.sh", try String(contentsOf: source, encoding: .utf8))
            try write("Sources/Core/Foo.swift", "struct Foo {}\n")
            try write("Sources/Core/Bar.swift", "struct Bar {}\n")
            try write("Tests/CoreTests/FooTests.swift", "@Suite struct FooTests {}\n@Suite struct FooMoreTests {}\n")
            try write("README.md", "hi\n")
        }

        func write(_ path: String, _ text: String) throws {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func sh(_ arguments: [String], executable: String = "/bin/sh") async throws -> [String] {
            var spawn = SpawnRequest(
                executable: URL(fileURLWithPath: executable), arguments: arguments,
                environment: [
                    "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_GLOBAL": "/dev/null",
                    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                    "GIT_COMMITTER_EMAIL": "t@t",
                ],
                workingDirectory: dir, timeout: 60)
            spawn.snapshotInterval = 3600
            var lines: [String] = []
            for await event in try ProcessRunner.start(spawn).events {
                if case .line(let line) = event { lines.append(line) }
            }
            return lines
        }

        func commitAll() async throws {
            _ = try await sh(["init", "-q", "-b", "main"], executable: "/usr/bin/git")
            _ = try await sh(["add", "-A"], executable: "/usr/bin/git")
            _ = try await sh(["commit", "-q", "-m", "base"], executable: "/usr/bin/git")
        }

        func plan() async throws -> String {
            try await sh(["scripts/check-changed.sh", "--plan", "HEAD"]).joined(separator: "\n")
        }
    }

    @Test func aChangedSourceRunsTheSuitesNamedInItsTestFile() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("Sources/Core/Foo.swift", "struct Foo { var x = 1 }\n")
        let plan = try await repo.plan()
        #expect(plan.contains("Lint: 1 changed Swift file"), "\(plan)")
        #expect(plan.contains("swift test --filter \"FooMoreTests|FooTests\""), "\(plan)")
    }

    @Test func aChangedTestFileRunsItsOwnSuites() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("Tests/CoreTests/FooTests.swift", "@Suite\nstruct FooTests {}\n@Suite struct Other {}\n")
        let plan = try await repo.plan()
        #expect(plan.contains("swift test --filter \"FooTests|Other\""), "\(plan)")
    }

    @Test func aSourceWithNoTestIsBuiltAndSaidSo() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("Sources/Core/Bar.swift", "struct Bar { var y = 2 }\n")
        let plan = try await repo.plan()
        #expect(plan.contains("No tests found for: Sources/Core/Bar.swift"), "\(plan)")
        #expect(plan.contains("run: swift build"), "\(plan)")
        #expect(!plan.contains("swift test"), "\(plan)")
    }

    @Test func untrackedFilesCount() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("Tests/CoreTests/NewTests.swift", "@Suite struct NewTests {}\n")
        let plan = try await repo.plan()
        #expect(plan.contains("Lint: 1 changed Swift file"), "\(plan)")
        #expect(plan.contains("swift test --filter \"NewTests\""), "\(plan)")
    }

    @Test func docsOnlyChangesRunNothing() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("README.md", "changed\n")
        let plan = try await repo.plan()
        #expect(plan.contains("No Swift files changed"), "\(plan)")
        #expect(!plan.contains("run:"), "\(plan)")
    }

    @Test func noChangeRunsNothing() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        let plan = try await repo.plan()
        #expect(plan.contains("Nothing changed"), "\(plan)")
    }

    @Test func aPackageChangeFallsBackToTheFullCheck() async throws {
        let repo = try Repo()
        try repo.write("Package.swift", "// p\n")
        try await repo.commitAll()
        try repo.write("Package.swift", "// p2\n")
        let plan = try await repo.plan()
        #expect(plan.contains("run: scripts/check.sh"), "\(plan)")
    }

    @Test func aBaseThatIsNotACommitFailsInsteadOfPassing() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        let out = try await repo.sh(["-c", "sh scripts/check-changed.sh --plan origin/main 2>&1; echo exit=$?"])
            .joined(separator: "\n")
        #expect(out.contains("is not a commit here"), "\(out)")
        #expect(out.contains("exit=1"), "\(out)")
    }

    @Test func aDeletedSourceStillBuildsWhatRemains() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try FileManager.default.removeItem(at: repo.dir.appendingPathComponent("Sources/Core/Bar.swift"))
        let plan = try await repo.plan()
        #expect(plan.contains("Lint: nothing"), "\(plan)")
        #expect(plan.contains("run: swift build"), "\(plan)")
        #expect(!plan.contains("Nothing changed"), "\(plan)")
    }

    @Test func aDeletedLintConfigStillForcesTheFullCheck() async throws {
        let repo = try Repo()
        try repo.write(".swiftlint.yml", "strict: true\n")
        try await repo.commitAll()
        try FileManager.default.removeItem(at: repo.dir.appendingPathComponent(".swiftlint.yml"))
        let plan = try await repo.plan()
        #expect(plan.contains("run: scripts/check.sh"), "\(plan)")
    }

    @Test func committedChangesCountAgainstTheBase() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("Sources/Core/Foo.swift", "struct Foo { var x = 1 }\n")
        _ = try await repo.sh(["commit", "-qam", "change"], executable: "/usr/bin/git")
        let out = try await repo.sh(["scripts/check-changed.sh", "--plan", "HEAD~1"]).joined(separator: "\n")
        #expect(out.contains("swift test --filter \"FooMoreTests|FooTests\""), "\(out)")
    }
}
