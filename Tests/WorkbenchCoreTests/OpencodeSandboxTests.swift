import Foundation
import Testing

@testable import WorkbenchCore

private let user = OpencodeSandbox.UserDirectories(
    temp: URL(fileURLWithPath: "/private/var/folders/ab/cd.e+f/T/"),
    cache: URL(fileURLWithPath: "/private/var/folders/ab/cd.e+f/C"))

private func profile(
    worktree: String = "/w/wt", scratch: String = "/o/scratch", state: String = "/o/state", denyReads: [String] = []
) throws -> String {
    try OpencodeSandbox.profile(
        worktree: URL(fileURLWithPath: worktree), scratch: URL(fileURLWithPath: scratch), state: URL(fileURLWithPath: state),
        user: user, denyReads: denyReads.map { URL(fileURLWithPath: $0) })
}

@Suite struct OpencodeSandboxProfileTests {
    @Test func writesGoToTheWorktreeTheScratchDirectoryAndTheRunsStateAndNowhereElse() throws {
        let text = try profile()
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.prefix(3) == ["(version 1)", "(allow default)", "(deny file-write*)"])
        let allow = try #require(lines.first { $0.hasPrefix("(allow file-write*") && $0.contains("/w/wt") })
        for path in ["/w/wt", "/o/scratch", "/o/state"] { #expect(allow.contains("(subpath \"\(path)\")"), "\(path)") }
        let allowLines = text.components(separatedBy: "(allow file-write*").count - 1
        #expect(allowLines == 2, "the run's own paths, and the names macOS tools create in the shared temp directory")
    }

    @Test func gitIsDeniedAfterTheAllowBecauseTheLastMatchingRuleWins() throws {
        let lines = try profile().split(separator: "\n").map(String.init)
        let allow = try #require(lines.firstIndex { $0.contains("(subpath \"/w/wt\")") && $0.hasPrefix("(allow") })
        let deny = try #require(lines.firstIndex { $0.hasPrefix("(deny file-write*") && $0.contains("/w/wt/.git") })
        #expect(deny > allow)
        #expect(lines[deny].contains("(literal \"/w/wt/.git\")"), "a linked worktree's .git is a file")
        #expect(lines[deny].contains("(subpath \"/w/wt/.git\")"))
    }

    @Test func theNetworkIsLoopbackOnlyAndTheServerCanBindThere() throws {
        let text = try profile()
        #expect(text.contains("(deny network*)"))
        #expect(text.contains("(allow network* (remote ip \"localhost:*\"))"))
        let bind = "(allow network-bind (local ip \"localhost:*\"))"
        #expect(text.contains(bind), "without it the standalone server dies unexplained")
        #expect(text.contains("(allow network-inbound (local ip \"localhost:*\"))"))
        let allows = text.split(separator: "\n").filter { $0.hasPrefix("(allow network") }
        #expect(allows.allSatisfy { $0.contains("localhost") }, "seatbelt cannot name a host, so nothing but loopback is allowed")
    }

    @Test func theSharedTempDirectoryOnlyAllowsTheNamesMacOSToolsCreateInIt() throws {
        let text = try profile()
        #expect(text.contains(#"(regex #"^/private/var/folders/ab/cd\.e\+f/T/(xcrun_db|xcrun_db-|tmp\.)[^/]*")"#))
        #expect(text.contains("(subpath \"/private/var/folders/ab/cd.e+f/T/TemporaryItems\")"))
        #expect(text.contains("(subpath \"/private/var/folders/ab/cd.e+f/C/clang/ModuleCache\")"))
        #expect(!text.contains("(subpath \"/private/var/folders/ab/cd.e+f/T\")"), "never the whole shared directory")
        #expect(!text.contains("(subpath \"/private/var/folders/ab/cd.e+f/C\")"))
    }

    @Test func credentialDirectoriesAreDeniedForReadingWhenNamed() throws {
        let text = try profile(denyReads: ["/h/.ssh", "/h/.local/share/opencode"])
        #expect(text.contains("(deny file-read* (subpath \"/h/.ssh\"))"))
        #expect(text.contains("(deny file-read* (subpath \"/h/.local/share/opencode\"))"))
        #expect(try !profile().contains("file-read"))
    }

    @Test func theDefaultCredentialListCoversTheLoginsAnotherAgentAndTheUsersOwnOpencodeHold() {
        let paths = OpencodeSandbox.credentialDirectories(home: URL(fileURLWithPath: "/h")).map(\.path)
        let expectedPaths = [
            "/h/.ssh", "/h/.aws", "/h/.config/gh", "/h/.config/opencode", "/h/.local/share/opencode", "/h/.claude", "/h/.codex",
        ]
        for expected in expectedPaths {
            #expect(paths.contains(expected), "\(expected)")
        }
    }

    @Test(arguments: ["/w/a\"b", "/w/a\\b", "/w/a\nb", "/w/a\u{7}b", "/"])
    func aPathThatCouldEndTheStringOrIsNotAbsoluteIsRefused(path: String) {
        #expect(throws: OpencodeSetupError.self) { try profile(worktree: path) }
        #expect(throws: OpencodeSetupError.self) { try profile(scratch: path) }
        #expect(throws: OpencodeSetupError.self) { try profile(denyReads: [path]) }
    }

    @Test func aRelativePathIsRefusedBecauseTheProfileNeedsTheRealOne() throws {
        let relative = try #require(URL(string: "relative/wt"))
        #expect(throws: OpencodeSetupError.self) {
            try OpencodeSandbox.profile(
                worktree: relative, scratch: URL(fileURLWithPath: "/s"), state: URL(fileURLWithPath: "/t"), user: user)
        }
    }

    @Test func theTempPathIsEscapedWhereItIsARegexAndValidatedLikeTheOthers() {
        #expect(OpencodeSandbox.regexEscaped("/a.b+c(d)[e]{f}|g^h$i*j?k\\l") == #"/a\.b\+c\(d\)\[e\]\{f\}\|g\^h\$i\*j\?k\\l"#)
        let hostile = OpencodeSandbox.UserDirectories(temp: URL(fileURLWithPath: "/t\"x"), cache: URL(fileURLWithPath: "/c"))
        #expect(throws: OpencodeSetupError.self) {
            try OpencodeSandbox.profile(
                worktree: URL(fileURLWithPath: "/w"), scratch: URL(fileURLWithPath: "/s"), state: URL(fileURLWithPath: "/t"),
                user: hostile)
        }
    }

    #if os(macOS)
        @Test func theUserDirectoriesAreRealPathsUnderVarFolders() throws {
            let dirs = try #require(OpencodeSandbox.userDirectories())
            #expect(dirs.temp.path.hasPrefix("/private/var/folders/") && dirs.cache.path.hasPrefix("/private/var/folders/"))
            #expect(dirs.temp.path != dirs.cache.path)
        }
    #endif
}

#if os(macOS)
    /// The profile is only worth what the kernel does with it, so this runs `sandbox-exec` for real: nothing here asks the model.
    @Suite struct OpencodeSandboxEnforcementTests {
        private struct Fixture {
            let root: URL, worktree: URL, scratch: URL, state: URL, outside: URL
            init() throws {
                let base = try #require(realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) })
                root = URL(fileURLWithPath: base).appendingPathComponent("oc-sandbox-\(UUID().uuidString)")
                worktree = root.appendingPathComponent("wt")
                scratch = root.appendingPathComponent("scratch")
                state = root.appendingPathComponent("state")
                outside = root.appendingPathComponent("outside")
                for dir in [worktree, scratch, state, outside] {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                let git = worktree.appendingPathComponent(".git")
                try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            }
            func cleanUp() { try? FileManager.default.removeItem(at: root) }

            /// Runs `script` under the profile, with its working directory in the worktree, and says whether it exited 0.
            func run(_ script: String, deny: [URL] = []) throws -> Bool {
                let dirs = try #require(OpencodeSandbox.userDirectories())
                let text = try OpencodeSandbox.profile(
                    worktree: worktree, scratch: scratch, state: state, user: dirs, denyReads: deny)
                let file = root.appendingPathComponent("p.sb")
                try text.write(to: file, atomically: true, encoding: .utf8)
                let null = open("/dev/null", O_WRONLY)
                defer { close(null) }
                let pid = try Spawner.spawn(
                    executable: "/usr/bin/sandbox-exec", arguments: ["-f", file.path, "/bin/sh", "-c", script],
                    environment: ["PATH": "/usr/bin:/bin", "TMPDIR": scratch.path], workingDirectory: worktree.path, stdout: null,
                    stderr: null)
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                return status == 0
            }
        }

        @Test func aShellMayWriteTheWorktreeAndTheScratchDirectoryButNothingOutside() throws {
            let f = try Fixture()
            defer { f.cleanUp() }
            #expect(try f.run("echo a > in.txt && echo b > \(f.scratch.path)/s.txt && echo c > \(f.state.path)/st.txt"))
            #expect(try !f.run("echo x > \(f.outside.path)/o.txt"))
            #expect(!FileManager.default.fileExists(atPath: f.outside.appendingPathComponent("o.txt").path))
        }

        @Test func aSymlinkOutOfTheWorktreeDoesNotCarryAWriteOut() throws {
            let f = try Fixture()
            defer { f.cleanUp() }
            #expect(try !f.run("ln -s \(f.outside.path) link && echo x > link/sym.txt"))
            #expect(!FileManager.default.fileExists(atPath: f.outside.appendingPathComponent("sym.txt").path))
        }

        @Test func nothingIsWrittenUnderGitSoACommitInTheWorktreeFails() throws {
            let f = try Fixture()
            defer { f.cleanUp() }
            #expect(try !f.run("echo x > .git/index.lock"))
            #expect(!FileManager.default.fileExists(atPath: f.worktree.appendingPathComponent(".git/index.lock").path))
        }

        @Test func thereIsNoNetworkButLoopback() throws {
            let f = try Fixture()
            defer { f.cleanUp() }
            // Neither name resolution nor a connection to a public address can start.
            #expect(try !f.run("/usr/bin/curl -s -m 5 -o /dev/null https://example.com"))
            #expect(try !f.run("/usr/bin/curl -s -m 5 -o /dev/null http://93.184.216.34/"))
        }

        @Test func aWrappedCommandIsConfinedAsMuchAsAPlainOne() throws {
            let f = try Fixture()
            defer { f.cleanUp() }
            // The probes' bypasses of OpenCode's own `bash` rules: the process around them is what holds.
            #expect(try !f.run("bash -c 'echo x > \(f.outside.path)/b.txt'"))
            #expect(try !f.run("python3 -c \"open('\(f.outside.path)/p.txt','w').write('x')\""))
            #expect(try !f.run("cp /etc/hosts \(f.outside.path)/cp.txt"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.outside.path).isEmpty)
        }

        @Test func theSharedTempDirectoryIsNotWritableExceptForTheNamesToolsNeed() throws {
            let f = try Fixture()
            defer { f.cleanUp() }
            let dirs = try #require(OpencodeSandbox.userDirectories())
            let stray = dirs.temp.appendingPathComponent("oc-stray-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: stray) }
            #expect(try !f.run("echo x > \(stray.path)"))
            #expect(!FileManager.default.fileExists(atPath: stray.path))
            #expect(try f.run("d=$(mktemp -d) && rmdir \"$d\""), "mktemp -d uses confstr, not TMPDIR, and needs its tmp.* names")
        }

        @Test func aNamedCredentialDirectoryCannotBeRead() throws {
            let f = try Fixture()
            defer { f.cleanUp() }
            try "secret".write(to: f.outside.appendingPathComponent("key"), atomically: true, encoding: .utf8)
            #expect(try f.run("cat \(f.outside.path)/key"), "reads are open unless a directory is named")
            #expect(try !f.run("cat \(f.outside.path)/key", deny: [f.outside]))
        }
    }
#endif
