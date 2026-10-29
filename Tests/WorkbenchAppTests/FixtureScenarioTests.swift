import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct FixtureScenarioTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var committed: URL { repositoryRoot.appendingPathComponent("Fixtures/app") }

    /// Not a test: with `WORKBENCH_WRITE_FIXTURES=<directory>` set it rewrites the committed scenarios, else it does nothing.
    @Test func writeTheScenarios() async throws {
        guard let path = ProcessInfo.processInfo.environment["WORKBENCH_WRITE_FIXTURES"], !path.isEmpty else { return }
        try await AppScenario.writeAll(into: URL(fileURLWithPath: path, relativeTo: repositoryRoot))
    }

    private func files(under root: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        // The temporary folder is /var/... and its files come back as /private/var/...: compare resolved paths, or every key is wrong.
        let base = root.resolvingSymlinksInPath().path
        let resolved = root.resolvingSymlinksInPath()
        let items = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = items?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found[String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return found
    }

    @Test func theCommittedFixturesAreWhatTheHelperWrites() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("scenarios-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await AppScenario.writeAll(into: scratch)
        let expected = try files(under: scratch)
        let have = try files(under: committed)
        let rewrite = "WORKBENCH_WRITE_FIXTURES=Fixtures/app swift test --filter FixtureScenarioTests/writeTheScenarios"
        #expect(Set(have.keys) == Set(expected.keys), "the files differ; rewrite them: \(rewrite)")
        for (path, data) in expected where have[path] != data {
            Issue.record("\(path) differs from what the helper writes; rewrite them: \(rewrite)")
        }
        #expect(expected.keys.contains { $0.hasPrefix("needs-you/threads/") })
    }

    /// What `verify-app.sh start` does: copy the scenario's threads into a project's `.workbench/`, then open it.
    private func project(for scenario: AppScenario) throws -> Project {
        let name = "scenario-\(scenario.rawValue)-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let threads = root.appendingPathComponent(".workbench/threads")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".workbench"), withIntermediateDirectories: true)
        let source = committed.appendingPathComponent(scenario.rawValue).appendingPathComponent("threads")
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: source, to: threads)
        } else {
            try FileManager.default.createDirectory(at: threads, withIntermediateDirectories: true)
        }
        let config = committed.appendingPathComponent(scenario.rawValue).appendingPathComponent("config.toml")
        if FileManager.default.fileExists(atPath: config.path) {
            try FileManager.default.copyItem(at: config, to: root.appendingPathComponent(".workbench/config.toml"))
        }
        return Project(root: root)
    }

    private func screen(_ scenario: AppScenario) throws -> ProjectScreen {
        let project = try project(for: scenario)
        defer { try? FileManager.default.removeItem(at: project.root) }
        return ProjectLoader.load(project: project).screen
    }

    private func thread(_ scenario: AppScenario) throws -> ThreadSnapshot {
        guard case .thread(let shown) = try screen(scenario) else { throw ScenarioError.notAThread(scenario.rawValue) }
        return shown
    }

    @Test func eachScenarioOpensToTheScreenItIsFor() throws {
        let draft = try thread(.draft)
        #expect(draft.spine[.goal].sublabel == "Writing" && draft.attention == .none)
        #expect(draft.title == "Paginate the contractor invoice list")
        #expect(try thread(.running).attention == .working)
        let needsYou = try thread(.needsYou)
        #expect(needsYou.spendText == "$1.88 of $5.00")
        if case .needsYou = needsYou.attention {} else { Issue.record("needs-you is not amber: \(needsYou.attention)") }
        #expect(try thread(.prOpen).spine[.ship].sublabel == "PR #482 open")
        #expect(try thread(.accepted).canShip && !(try thread(.prOpen).canShip))
        let cleaned = try thread(.cleaned)
        #expect(cleaned.spine[.clean].mark == .done && cleaned.spendText == "unknown of $5.00")
        if case .logCorrupt(let id, _) = try screen(.corrupt) {
            #expect(id == "invoice-pagination")
        } else {
            Issue.record("corrupt did not read as corrupt")
        }
        #expect(try screen(.noThread) == .noThread)
        #expect(try screen(.draftGoal) == .noThread)
    }

    @Test func theDraftGoalScenarioNamesTheRealCodexAsTheGoalAgentAndTheConfigLoads() throws {
        let project = try project(for: .draftGoal)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let config = try Config.load(from: project.configURL)
        #expect(config.resolvedGoalAgent?.provider == .codex)
    }

    @Test func theGoalScenariosShowTheWarningAndTheApprovedGoal() async throws {
        let warned = try project(for: .goalWarning)
        let approved = try project(for: .goalApproved)
        defer { for project in [warned, approved] { try? FileManager.default.removeItem(at: project.root) } }
        let model = await GoalModel.load(project: warned, thread: "invoice-pagination") { _, _ in false }
        #expect(model.checkableText == "1 of 3 checkable" && !model.canApprove)
        #expect(model.rows.compactMap(\.warning).count == 2)
        let ok = await GoalModel.load(project: approved, thread: "invoice-pagination") { _, _ in false }
        #expect(ok.pill == .approved && ok.canApprove)
    }

    @Test func everyScenarioNameIsASafeFolderName() {
        for scenario in AppScenario.allCases {
            #expect(scenario.rawValue.range(of: "^[a-z][a-z-]*$", options: .regularExpression) != nil)
        }
    }
}

private enum ScenarioError: Error { case notAThread(String) }
