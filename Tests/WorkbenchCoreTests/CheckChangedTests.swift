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

        func sh(
            _ arguments: [String], executable: String = "/bin/sh", path: String = "/usr/bin:/bin"
        ) async throws -> [String] {
            var spawn = SpawnRequest(
                executable: URL(fileURLWithPath: executable), arguments: arguments,
                environment: [
                    "PATH": path, "HOME": NSHomeDirectory(), "GIT_CONFIG_GLOBAL": "/dev/null",
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
        #expect(plan.contains("run: swift build --build-tests"), "\(plan)")
        #expect(plan.contains("swift test --skip-build --filter \"FooMoreTests|FooTests\""), "\(plan)")
    }

    @Test func aChangedTestFileRunsItsOwnSuites() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("Tests/CoreTests/FooTests.swift", "@Suite\nstruct FooTests {}\n@Suite struct Other {}\n")
        let plan = try await repo.plan()
        #expect(plan.contains("swift test --skip-build --filter \"FooTests|Other\""), "\(plan)")
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
        #expect(plan.contains("swift test --skip-build --filter \"NewTests\""), "\(plan)")
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
        #expect(out.contains("swift test --skip-build --filter \"FooMoreTests|FooTests\""), "\(out)")
    }

    @Test func aChangeToTheScriptItselfForcesTheFullCheck() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        let script = try String(contentsOf: repo.dir.appendingPathComponent("scripts/check-changed.sh"), encoding: .utf8)
        try repo.write("scripts/check-changed.sh", script + "# edited\n")
        let plan = try await repo.plan()
        #expect(plan.contains("run: scripts/check.sh"), "\(plan)")
    }

    @Test func aPathWithWhitespaceForcesTheFullCheck() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("Sources/Core/My File.swift", "struct MyFile {}\n")
        let plan = try await repo.plan()
        #expect(plan.contains("whitespace or needs quoting: full check"), "\(plan)")
    }

    @Test func aNonASCIIFilenameIsStillSeen() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("Sources/Core/Café.swift", "struct Cafe {}\n")
        let plan = try await repo.plan()
        #expect(plan.contains("Lint: 1 changed Swift file"), "\(plan)")
    }

    // MARK: execution, with stand-ins for swiftlint and swift

    /// Stand-in tools on PATH that append their arguments to `calls.log`; `fail` names one that exits 1.
    private func stubbed(_ repo: Repo, fail: String? = nil) throws -> String {
        for tool in ["swiftlint", "swift"] {
            // "swift test" fails only the test run, so the build before it passes.
            let code = fail == tool ? 1 : 0
            let failsTest = tool == "swift" && fail == "swift test" ? "[ \"$1\" = test ] && exit 1\n" : ""
            try repo.write(
                "stubs/\(tool)", "#!/bin/sh\necho \"\(tool) $*\" >> \"$PWD/calls.log\"\n\(failsTest)exit \(code)\n")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: repo.dir.appendingPathComponent("stubs/\(tool)").path)
        }
        try repo.write("scripts/check-banned-apis.sh", "#!/bin/sh\necho \"banned-apis\" >> \"$PWD/calls.log\"\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: repo.dir.appendingPathComponent("scripts/check-banned-apis.sh").path)
        return repo.dir.appendingPathComponent("stubs").path + ":/usr/bin:/bin"
    }

    private func calls(_ repo: Repo) throws -> [String] {
        let log = try String(contentsOf: repo.dir.appendingPathComponent("calls.log"), encoding: .utf8)
        return log.split(separator: "\n").map(String.init)
    }

    @Test func runningItLintsTheChangedFilesThenTestsTheirSuites() async throws {
        let repo = try Repo()
        let path = try stubbed(repo)
        try await repo.commitAll()
        try repo.write("Sources/Core/Foo.swift", "struct Foo { var x = 1 }\n")
        let out = try await repo.sh(["-c", "sh scripts/check-changed.sh HEAD 2>&1"], path: path)
        #expect(out.last?.contains("Changed-file checks passed") == true, "\(out)")
        #expect(
            try calls(repo) == [
                "banned-apis", "swiftlint lint --quiet Sources/Core/Foo.swift",
                "swift build --build-tests", "swift test --skip-build --filter FooMoreTests|FooTests",
            ])
    }

    @Test func aRunSaysHowManySuitesItChoseAndWhereTheTimeWent() async throws {
        let repo = try Repo()
        let path = try stubbed(repo)
        try await repo.commitAll()
        try repo.write("Sources/Core/Foo.swift", "struct Foo { var x = 1 }\n")
        let out = try await repo.sh(["-c", "sh scripts/check-changed.sh HEAD 2>&1"], path: path)
            .joined(separator: "\n")
        #expect(out.contains("Test suites (2): FooMoreTests|FooTests"), "\(out)")
        #expect(out.contains("==> Timing, "), "\(out)")
        for step in ["Banned process APIs", "SwiftLint", "Build tests", "Test"] {
            #expect(out.contains("    \(step): "), "\(step) missing from the timing\n\(out)")
        }
    }

    @Test func aFailingLintStopsBeforeTheTests() async throws {
        let repo = try Repo()
        let path = try stubbed(repo, fail: "swiftlint")
        try await repo.commitAll()
        try repo.write("Sources/Core/Foo.swift", "struct Foo { var x = 1 }\n")
        let out = try await repo.sh(["-c", "sh scripts/check-changed.sh HEAD 2>&1; echo exit=$?"], path: path)
        #expect(out.contains("exit=1"), "\(out)")
        #expect(try calls(repo).contains { $0.hasPrefix("swift test") } == false)
    }

    @Test func aFailingTestFailsTheCheck() async throws {
        let repo = try Repo()
        let path = try stubbed(repo, fail: "swift test")
        try await repo.commitAll()
        try repo.write("Sources/Core/Foo.swift", "struct Foo { var x = 1 }\n")
        let out = try await repo.sh(["-c", "sh scripts/check-changed.sh HEAD 2>&1; echo exit=$?"], path: path)
        #expect(out.contains("exit=1"), "\(out)")
        #expect(try calls(repo).contains { $0.hasPrefix("swift test") }, "the test run was never reached")
        // The steps that passed keep their time in the failure output.
        #expect(out.joined(separator: "\n").contains("    Build tests: "), "\(out)")
    }

    @Test func aFailingBuildFailsTheCheckBeforeTheTests() async throws {
        let repo = try Repo()
        let path = try stubbed(repo, fail: "swift")
        try await repo.commitAll()
        try repo.write("Sources/Core/Foo.swift", "struct Foo { var x = 1 }\n")
        let out = try await repo.sh(["-c", "sh scripts/check-changed.sh HEAD 2>&1; echo exit=$?"], path: path)
        #expect(out.contains("exit=1"), "\(out)")
        #expect(try calls(repo).contains { $0.hasPrefix("swift test") } == false)
    }

    @Test func aChangedTestHelperWithNoSuiteCompilesTheTestTargets() async throws {
        let repo = try Repo()
        try repo.write("Tests/CoreTests/Helper.swift", "struct Helper {}\n")
        try await repo.commitAll()
        try repo.write("Tests/CoreTests/Helper.swift", "struct Helper { var x = 1 }\n")
        let plan = try await repo.plan()
        #expect(plan.contains("run: swift build --build-tests"), "\(plan)")
        #expect(!plan.contains("swift test"), "\(plan)")
    }

    @Test func aPathGitQuotesForcesTheFullCheck() async throws {
        let repo = try Repo()
        try await repo.commitAll()
        try repo.write("Sources/Core/Tab\tName.swift", "struct TabName {}\n")
        let plan = try await repo.plan()
        #expect(plan.contains("run: scripts/check.sh"), "\(plan)")
    }
}
