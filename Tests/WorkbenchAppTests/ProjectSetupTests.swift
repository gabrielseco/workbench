import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// Setting up a folder that is a git repository but not a Workbench project yet: from the window (`ProjectStore.initializeProject`) and
/// in core (`ProjectSetup.initialize`).
@MainActor @Suite struct ProjectSetupTests {
    private func store(_ actions: GoalActions = GoalActions()) -> ProjectStore {
        ProjectStore(
            preferences: MemoryPreferences(projectPath: nil), intervals: (.milliseconds(20), .milliseconds(20)), actions: actions)
    }

    /// A repository with files of its own and no `.workbench/`.
    private func repository() async throws -> AppFixture {
        let fixture = try await AppFixture(workbench: false)
        try "# Boats\n".write(to: fixture.root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let sources = fixture.root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "print(1)\n".write(to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return fixture
    }

    /// Every file of the folder outside `.git/` and `.workbench/`, with its bytes.
    private func projectFiles(_ fixture: AppFixture) -> [String: Data] {
        let root = fixture.project.root
        var found: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            if relative == ".git" || relative == ".workbench" {
                walker?.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                found[relative] = try? Data(contentsOf: url)
            }
        }
        return found
    }

    private func gitStatus(_ fixture: AppFixture) async throws -> String {
        try await GitRunner.discover().run(["status", "--porcelain", "--untracked-files=all"], in: fixture.root).stdout
    }

    // MARK: c2: the goal agent picked is the one the project discusses and drafts with

    @Test func initializesWithGoalAgent() async throws {
        let fixture = try await repository()
        let before = projectFiles(fixture)
        let store = store()
        #expect(await store.open(fixture.root))
        #expect(store.screen == .workbenchMissing(path: fixture.project.root.path))
        #expect(store.offersSetup)
        #expect(store.setup.goalAgent == .claude, "Claude is picked until the person picks otherwise")

        store.pickSetupGoalAgent(.codex)
        await store.initializeProject()

        #expect(store.setup.failure == nil)
        let config = try Config.load(from: fixture.project.configURL)
        // What chat and drafting are gated on (`ChatRefusal.noGoalAgent`, `GoalDraftRefusal.noGoalAgent`): the agent picked.
        #expect(config.resolvedGoalAgent?.provider == .codex)
        #expect(AgentSetup.chatAgent(config) == "Codex · default model")
        // The project opens on New goal, where the person can discuss or draft with it.
        #expect(store.screen == .noThread && store.newThread && !store.offersSetup)
        #expect(store.setup.done?.isEmpty == false)
        await store.refreshAgentSetup()
        guard case .read(let setup) = store.agentConfig else {
            Issue.record("\(store.agentConfig)")
            return
        }
        #expect(AgentSetup.chatAgent(for: setup) == "Codex · default model")
        // The folder's own files are as they were, and `.workbench/` is not something git offers to commit.
        #expect(projectFiles(fixture) == before)
        let status = try await gitStatus(fixture)
        #expect(!status.contains(".workbench"), "\(status)")
    }

    @Test func noGoalAgentLeavesChatAndDraftingOff() async throws {
        let fixture = try await repository()
        let store = store()
        #expect(await store.open(fixture.root))
        store.pickSetupGoalAgent(nil)
        await store.initializeProject()
        let config = try Config.load(from: fixture.project.configURL)
        #expect(config.resolvedGoalAgent == nil)
        #expect(store.screen == .noThread && !store.newThread)
    }

    @Test func aProviderThatCannotDraftIsRefusedBeforeAnythingIsWritten() async throws {
        let fixture = try await repository()
        let git = try GitRunner.discover()
        let other = try #require(AgentProviderID("gemini"))
        await #expect(throws: ProjectSetup.Failure.unsupported("gemini")) {
            try await ProjectSetup.initialize(fixture.project, goalAgent: other, git: git)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.project.workbenchDirectory.path))
    }

    // MARK: c3: what is there stays

    @Test func preservesExistingConfiguration() async throws {
        let git = try GitRunner.discover()

        // A config that names its own goal agent and other agents is left byte for byte, and its goal agent is the one kept.
        let named = try await repository()
        let files = projectFiles(named)
        let thread = named.project.threadDirectory("old")
        try FileManager.default.createDirectory(at: thread, withIntermediateDirectories: true)
        try "kept\n".write(to: thread.appendingPathComponent("goal.md"), atomically: true, encoding: .utf8)
        let text = """
            check_command = "scripts/check.sh"

            [agents.goal]
            provider = "codex"

            [agents.run]
            model = "opus"

            [tools]
            available = ["Read"]
            allowed = ["Read"]

            """
        try text.write(to: named.project.configURL, atomically: true, encoding: .utf8)
        let report = try await ProjectSetup.initialize(named.project, goalAgent: .claude, git: git)
        #expect(report == ProjectSetup.Report(wroteConfig: false, goalAgent: .codex, keptGoalAgent: true))
        #expect(try String(contentsOf: named.project.configURL, encoding: .utf8) == text)
        #expect(try String(contentsOf: thread.appendingPathComponent("goal.md"), encoding: .utf8) == "kept\n")
        #expect(projectFiles(named) == files)

        // A config with no goal agent gets `[agents.goal]` and nothing else changes: every line it had stays, in order.
        let unnamed = try await repository()
        try FileManager.default.createDirectory(at: unnamed.project.workbenchDirectory, withIntermediateDirectories: true)
        let plain = "check_command = \"scripts/check.sh\"\n\n[agents.run]\nmodel = \"opus\"\nreasoning_effort = \"high\"\n\n"
            + "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"
        try plain.write(to: unnamed.project.configURL, atomically: true, encoding: .utf8)
        let added = try await ProjectSetup.initialize(unnamed.project, goalAgent: .claude, git: git)
        #expect(added == ProjectSetup.Report(wroteConfig: false, goalAgent: .claude, keptGoalAgent: false))
        let after = try String(contentsOf: unnamed.project.configURL, encoding: .utf8)
        #expect(after.hasPrefix(plain), "\(after)")
        let config = try Config.load(from: unnamed.project.configURL)
        #expect(config.resolvedGoalAgent?.provider == .claude)
        #expect(config.resolvedRunAgent().model == "opus" && config.resolvedRunAgent().reasoningEffort == "high")
        #expect(config.checkCommand == "scripts/check.sh")

        // Setting up twice changes nothing the second time.
        _ = try await ProjectSetup.initialize(unnamed.project, goalAgent: .codex, git: git)
        #expect(try String(contentsOf: unnamed.project.configURL, encoding: .utf8) == after)

        // A project that has its config is opened as it is: no setup is offered.
        let store = store()
        #expect(await store.open(named.root))
        #expect(!store.offersSetup && store.screen != .workbenchMissing(path: named.project.root.path))
    }

    // MARK: c4: Not now changes nothing, a failure says why and can be tried again

    @Test func cancelAndFailure() async throws {
        // Not now: nothing is written, the window says what is missing and offers setup again.
        let skipped = try await repository()
        let files = projectFiles(skipped)
        let status = try await gitStatus(skipped)
        let quiet = store()
        #expect(await quiet.open(skipped.root))
        quiet.skipSetup()
        #expect(!quiet.offersSetup && quiet.screen == .workbenchMissing(path: skipped.project.root.path))
        #expect(quiet.screen.message?.title.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: skipped.project.workbenchDirectory.path))
        #expect(projectFiles(skipped) == files)
        #expect(try await gitStatus(skipped) == status)
        quiet.resumeSetup()
        #expect(quiet.offersSetup)

        // A failure stays on the setup screen with its reason; Try again runs it again and then it works.
        let failing = try await repository()
        let tries = Tries()
        let actions = GoalActions(initializeProject: { project, agent in
            if tries.next() == 1 { throw ProjectSetup.Failure.notWritten("the disk is full") }
            return try await ProjectSetup.initialize(project, goalAgent: agent, git: try GitRunner.discover())
        })
        let store = store(actions)
        #expect(await store.open(failing.root))
        await store.initializeProject()
        #expect(store.setup.failure?.contains("the disk is full") == true)
        #expect(store.offersSetup && !store.setup.running)
        #expect(store.screen == .workbenchMissing(path: failing.project.root.path))
        #expect(!FileManager.default.fileExists(atPath: failing.project.workbenchDirectory.path))
        await store.initializeProject()
        #expect(tries.count == 2)
        #expect(store.setup.failure == nil && store.screen == .noThread)
        #expect(FileManager.default.fileExists(atPath: failing.project.configURL.path))

        // Core's own failure partway (here `.git/info` is a file, so `.workbench/` cannot be excluded) removes what it wrote.
        let broken = try await repository()
        let before = projectFiles(broken)
        let info = broken.root.appendingPathComponent(".git/info")
        try FileManager.default.removeItem(at: info)
        try Data().write(to: info)
        let git = try GitRunner.discover()
        await #expect {
            try await ProjectSetup.initialize(broken.project, goalAgent: .claude, git: git)
        } throws: { error in
            if case ProjectSetup.Failure.exclude = error { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: broken.project.workbenchDirectory.path))
        #expect(projectFiles(broken) == before)
        // Once what was wrong is fixed, the same call works.
        try FileManager.default.removeItem(at: info)
        let report = try await ProjectSetup.initialize(broken.project, goalAgent: .claude, git: git)
        #expect(report.wroteConfig && report.goalAgent == .claude)

        // A failure after the goal agent was added to a config that was there puts that config back as it was.
        let existing = try await repository()
        try FileManager.default.createDirectory(at: existing.project.workbenchDirectory, withIntermediateDirectories: true)
        let text = "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"
        try text.write(to: existing.project.configURL, atomically: true, encoding: .utf8)
        let existingInfo = existing.root.appendingPathComponent(".git/info")
        try FileManager.default.removeItem(at: existingInfo)
        try Data().write(to: existingInfo)
        await #expect(throws: (any Error).self) {
            try await ProjectSetup.initialize(existing.project, goalAgent: .codex, git: git)
        }
        #expect(try String(contentsOf: existing.project.configURL, encoding: .utf8) == text)
    }
}

/// Counts the calls of a seam that runs off the main actor.
private final class Tries: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func next() -> Int { lock.withLock { calls += 1; return calls } }
    var count: Int { lock.withLock { calls } }
}
