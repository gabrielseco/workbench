import Foundation
import Testing

@testable import WorkbenchCore

private let sample = """
    ---
    id: g-2026-10-30-read
    title: Read next door
    status: draft
    base: main
    budget_usd: 5.00
    turn_timeout_min: 30
    ---

    ## Request

    Do the thing.

    ## Criteria

    - [c1] It is done.
      - proof: cat done

    ## Out of scope

    - Everything else.
    """

private func withLine(_ line: String) -> String {
    sample.replacingOccurrences(of: "turn_timeout_min: 30", with: "turn_timeout_min: 30\n\(line)")
}

@Suite struct GoalReadAlsoParsingTests {
    @Test func theFoldersAreReadAndTheEditorWritesAndClearsThem() throws {
        let file = try GoalFile.parse(withLine("read_also: ../backend, ~/shared"))
        #expect(file.goal.readAlso == ["../backend", "~/shared"])
        let edited = try GoalEditor.apply(.setReadAlso(["../api"]), to: GoalFile.parse(sample))
        #expect(edited.goal.readAlso == ["../api"] && edited.text.contains("read_also: ../api"))
        #expect(try GoalEditor.apply(.setReadAlso([]), to: edited).text == sample)
    }

    @Test func aBadListIsAGoalError() {
        let six = (1...6).map { "../r\($0)" }.joined(separator: ", ")
        for bad in ["read_also: ", "read_also: ../a,,../b", "read_also: ../a, ../a", "read_also: \(six)"] {
            #expect(throws: GoalParseError.self, "\(bad)") { try GoalFile.parse(withLine(bad)) }
        }
    }

    @Test func approvalBindsTheFoldersAndNotTheirOrder() throws {
        let approved = try GoalFile.parse(withLine("read_also: ../a, ../b")).approving()
        #expect(approved.goal.approval == .approved)
        #expect(try GoalEditor.apply(.setReadAlso(["../b", "../a"]), to: approved).goal.approval == .approved)
        #expect(try GoalEditor.apply(.setReadAlso(["../a", "../b", "../c"]), to: approved).goal.approval == .stale)
        let plain = GoalHash.hash(base: "main", spend: .hardCap(5), turnTimeoutMin: 30, body: "b")
        #expect(plain == GoalHash.hash(base: "main", spend: .hardCap(5), turnTimeoutMin: 30, readAlso: [], body: "b"))
        #expect(plain != GoalHash.hash(base: "main", spend: .hardCap(5), turnTimeoutMin: 30, readAlso: ["../a"], body: "b"))
    }
}

@Suite struct GoalReadAlsoEditorTests {
    @Test func theEditKeepsCommentsUnknownSectionsAndSpacing() throws {
        let rich = sample.replacingOccurrences(of: "base: main", with: "base: main  # the branch")
            .replacingOccurrences(of: "## Out of scope", with: "## Notes\n\nKept.\n\n\n## Out of scope")
        let edited = try GoalEditor.apply(.setReadAlso(["../a"]), to: GoalFile.parse(rich))
        #expect(edited.text.contains("base: main  # the branch"))
        #expect(edited.text.contains("## Notes\n\nKept.\n\n\n## Out of scope"))
        #expect(try GoalEditor.apply(.setReadAlso([]), to: edited).text == rich)
    }
}

@Suite(.processGate) struct GoalReadAlsoRunTests {
    private func checkout(_ fx: RunnerFixture) async throws -> URL {
        let dir = fx.repo.deletingLastPathComponent().appendingPathComponent("next-door-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await fx.git.run(["init", "-q"], in: dir)
        return dir.resolvingSymlinksInPath()
    }

    private func argvOf(_ path: String) throws -> [String] {
        let seen = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        return try #require(seen?["argv"] as? [String])
    }

    private func addDirs(_ path: String) throws -> [String] {
        let argv = try argvOf(path)
        let at = try #require(argv.firstIndex(of: "--add-dir"))
        return Array(argv[(at + 1)...].prefix { !$0.hasPrefix("--") })
    }

    @Test func aGoalsFolderIsReadOnlyForItsRunAfterTheConfigsAndEachOnce() async throws {
        let fx = try await RunnerFixture()
        let fromConfig = try await checkout(fx), fromGoal = try await checkout(fx)
        let text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        try "read_also = [\"\(fromConfig.path)\"]\n\(text)".write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let id = try await fx.approvedThread()
        try await fx.service.editGoal(id: id, .setReadAlso([fromGoal.path, fromConfig.path]))
        try await fx.service.approve(id: id)
        let dump = FakeClaude.scratch("dump.json")
        defer { try? FileManager.default.removeItem(atPath: dump) }
        let report = try await fx.runner(id).run(fx.options("dump=\(dump)"))
        #expect(report.result == .succeeded)
        #expect(try addDirs(dump) == [fromConfig.path, fromGoal.path])
        let argv = try argvOf(dump)
        #expect(argv.contains("Edit(/\(fromGoal.path)/**)") && argv.contains("Write(/\(fromGoal.path)/**)"), "read-only")
        let prompt = try String(contentsOf: fx.project.promptURL(id, turn: 1), encoding: .utf8)
        #expect(prompt.contains(fromGoal.path))
    }

    @Test func aFolderNamedTwiceByAnAliasCountsOnce() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        var folders: [URL] = []
        for _ in 1...5 { folders.append(try await checkout(fx)) }
        let relative = folders.map { "../" + $0.lastPathComponent }
        let text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        let list = relative.map { "\"\($0)\"" }.joined(separator: ", ")
        try "read_also = [\(list)]\n\(text)".write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        // The same checkout as the config's first, by its absolute path.
        try await fx.service.editGoal(id: id, .setReadAlso([folders[0].path]))
        _ = try await fx.service.approve(id: id)
        let resolved = try ReadAlso.resolve(config: relative, goal: [folders[0].path], projectRoot: fx.repo).get()
        #expect(resolved.count == 5)
    }

    @Test func approveRefusesAFolderThatIsNoCheckoutAndTooManyTogether() async throws {
        let fx = try await RunnerFixture()
        let id = try await fx.approvedThread()
        try await fx.service.editGoal(id: id, .setReadAlso(["../no-such-checkout"]))
        await #expect(throws: ThreadServiceError.self) { try await fx.service.approve(id: id) }

        var configured: [URL] = []
        for _ in 1...5 { configured.append(try await checkout(fx)) }
        let fromConfig = configured.map { "\"\($0.path)\"" }.joined(separator: ", ")
        let text = try String(contentsOf: fx.project.configURL, encoding: .utf8)
        try "read_also = [\(fromConfig)]\n\(text)".write(to: fx.project.configURL, atomically: true, encoding: .utf8)
        let real = try await checkout(fx)
        try await fx.service.editGoal(id: id, .setReadAlso([real.path]))
        await #expect(throws: ThreadServiceError.self) { try await fx.service.approve(id: id) }
    }
}
