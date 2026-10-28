import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// Counts how often the verifier's skill was asked about: it costs a git read, so it is asked only for a screenshot proof.
private final class SkillProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    let available: Bool
    init(available: Bool) { self.available = available }
    var asks: Int { lock.withLock { asked } }
    func ask() -> Bool { lock.withLock { asked += 1 }; return available }
}

@MainActor @Suite struct GoalScreenModelTests {
    private let config = """
        [tools]
        available = ["Read", "Bash"]
        allowed = ["Read", "Bash(swift test:*)"]
        """

    private func goal(_ proofs: [String], extra: String = "", frontMatter: String = "") -> String {
        let criteria = proofs.enumerated().map { "- [c\($0.offset + 1)] Holds \($0.offset + 1).\n  - proof: \($0.element)" }
            .joined(separator: "\n")
        return """
            ---
            id: t1
            title: The goal
            base: main
            budget_usd: 5
            turn_timeout_min: 30
            \(frontMatter)---

            ## Request

            Do the thing.\(extra)

            ## Criteria

            \(criteria)

            ## Out of scope

            - Everything else.

            """
    }

    private func load(
        goal text: String, config: String?, skill: SkillProbe = SkillProbe(available: true)
    ) async throws -> (GoalModel, SkillProbe) {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1")
        try text.write(to: fixture.project.goalURL("t1"), atomically: true, encoding: .utf8)
        if let config {
            try FileManager.default.createDirectory(
                at: fixture.project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try config.write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        }
        let model = await GoalModel.load(project: fixture.project, thread: "t1") { _, _ in skill.ask() }
        return (model, skill)
    }

    @Test func showsWhatTheGoalFileSaysAndWhereItIs() async throws {
        let (model, _) = try await load(goal: goal(["`swift test` passes"]), config: config)
        #expect(model.title == "The goal" && model.path == ".workbench/threads/t1/goal.md")
        #expect(model.request == "Do the thing." && model.outOfScope == ["Everything else."])
        #expect(model.rows.map(\.id) == ["c1"] && model.rows[0].proof.contains("swift test"))
        #expect(model.budget == "$5 per turn" && model.turnTimeout == "30 min per turn" && model.pill == .draft)
        #expect(model.allowedTools == ["Read", "Bash(swift test:*)"])
    }

    @Test func aTimeoutOnlyGoalSaysThereIsNoDollarCap() async throws {
        let text = goal(["`swift test` passes"]).replacingOccurrences(
            of: "budget_usd: 5", with: "spend_policy: timeout_only")
        let (model, _) = try await load(goal: text, config: config)
        #expect(model.budget == "no dollar cap: bounded by 30 min per turn")
    }

    @Test func countsTheCriteriaWithNoWarningAsCheckable() async throws {
        let (model, _) = try await load(
            goal: goal(["`swift test` passes", "`./scripts/deploy.sh` passes"]), config: config)
        #expect(model.checkableText == "1 of 2 checkable")
        #expect(model.rows[0].warning == nil && model.rows[1].warning?.contains("[tools] allowed") == true)
        #expect(!model.canApprove)
    }

    @Test func aScreenshotProofWithNoVerifierWarnsAndBlocksApproval() async throws {
        let (model, skill) = try await load(
            goal: goal(["screenshot: settings"]), config: config, skill: SkillProbe(available: false))
        #expect(skill.asks == 1 && model.checkableText == "0 of 1 checkable")
        #expect(model.rows[0].warning?.contains("no verifier skill") == true)
        #expect(!model.canApprove)
    }

    @Test func aScreenshotProofWithAVerifierIsCheckable() async throws {
        let (model, _) = try await load(goal: goal(["screenshot: settings"]), config: config)
        #expect(model.rows[0].warning == nil && model.canApprove)
    }

    @Test func theVerifierSkillIsOnlyReadForAScreenshotProof() async throws {
        let (model, skill) = try await load(goal: goal(["`swift test` passes"]), config: config)
        #expect(skill.asks == 0 && model.canApprove)
    }

    @Test func noConfigMeansNoProofIsJudged() async throws {
        let (model, skill) = try await load(goal: goal(["`./scripts/deploy.sh` passes", "screenshot: x"]), config: nil)
        #expect(model.rows.allSatisfy { $0.warning == nil } && skill.asks == 0)
        #expect(model.blockers.isEmpty && model.canApprove)
    }

    @Test func aConfigThatDoesNotParseIsShownAndBlocksApproval() async throws {
        let (model, _) = try await load(goal: goal(["`swift test` passes"]), config: "[tools\nbroken")
        #expect(model.blockers.first?.hasPrefix("The config does not load") == true)
        #expect(!model.canApprove)
    }

    @Test func aGoalThatDoesNotParseShowsItsProblems() async throws {
        let (model, _) = try await load(goal: "no front matter\n", config: config)
        #expect(!model.canApprove && model.rows.isEmpty)
        #expect(model.blockers.joined().contains("front matter"))
    }

    @Test func aPlaceholderBlocksApproval() async throws {
        let (model, _) = try await load(goal: goal(["`swift test` passes"], extra: "\nTODO(workbench): fill in"), config: config)
        #expect(model.blockers.contains { $0.contains("TODO(workbench)") } && !model.canApprove)
    }

    @Test func aGoalEditedAfterApprovalReadsChangedSinceApproval() async throws {
        let approved = goal(["`swift test` passes"])
        let hash = try GoalFile.parse(approved).goal.contentHash
        let marked = goal(["`swift test` passes"], frontMatter: "status: approved\napproved_hash: \(hash)\n")
        let (same, _) = try await load(goal: marked, config: config)
        #expect(same.pill == .approved)
        let edited = marked.replacingOccurrences(of: "Do the thing.", with: "Do another thing.")
        let (changed, _) = try await load(goal: edited, config: config)
        #expect(changed.pill == .changedSinceApproval)
    }

    @Test func editingTheFileAfterApprovalShowsOnTheOpenWindowWithoutRelaunch() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil))
        #expect(await store.open(fixture.root))
        #expect(store.goal?.pill == .approved)
        let url = fixture.project.goalURL("t1")
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "Do the thing.", with: "Do another thing.")
            .write(to: url, atomically: true, encoding: .utf8)
        // `stat` has a one-second floor on some filesystems; the poll reads again once the time moved.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        await store.refresh()
        #expect(store.goal?.pill == .changedSinceApproval && store.goal?.canApprove == true)
    }

    // MARK: The buttons

    private func actionsStore(
        approve: @escaping @Sendable (Project, String) async throws -> Void,
        run: @escaping @Sendable (Project, String) async throws -> Void
    ) async throws -> (ProjectStore, AppFixture) {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1")
        let actions = GoalActions(approve: approve, run: run, newThread: { _, _ in }, openGoal: { _, _ in })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root))
        return (store, fixture)
    }

    private struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }

    @Test func aFailedApproveStartsNoRunAndSaysWhy() async throws {
        let ran = Flag()
        let (store, _) = try await actionsStore(approve: { _, _ in throw Refused() }, run: { _, _ in ran.set() })
        await store.approveAndRun()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ran.value && store.actionError == "refused")
    }

    @Test func aRunThatCannotStartIsReported() async throws {
        let (store, _) = try await actionsStore(approve: { _, _ in }, run: { _, _ in throw Refused() })
        await store.approveAndRun()
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.actionError == "The run did not start: refused")
    }

    @Test func aGoalCanBeStartedFromAProjectWithNoThread() async throws {
        let made = Order()
        let fixture = try await AppFixture()
        let actions = GoalActions(
            approve: { _, _ in }, run: { _, _ in }, newThread: { _, name in made.add(name) }, openGoal: { _, _ in })
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: actions)
        #expect(await store.open(fixture.root) && store.screen == .noThread)
        await store.newGoal(name: "first")
        #expect(made.items == ["first"] && store.actionError == nil)
    }

    @Test func leavingTheProjectWhileApprovingStartsNoRun() async throws {
        let ran = Flag()
        let release = Gate()
        let (store, _) = try await actionsStore(approve: { _, _ in await release.wait() }, run: { _, _ in ran.set() })
        let other = try await AppFixture()
        let approving = Task { await store.approveAndRun() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await store.open(other.root))
        release.open()
        await approving.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ran.value)
    }

    @Test func approveRunsBeforeTheRun() async throws {
        let order = Order()
        let (store, _) = try await actionsStore(
            approve: { _, _ in order.add("approve") }, run: { _, _ in order.add("run") })
        await store.approveAndRun()
        try await Task.sleep(for: .milliseconds(200))
        #expect(order.items == ["approve", "run"] && store.actionError == nil)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ item: String) { lock.withLock { list.append(item) } }
    var items: [String] { lock.withLock { list } }
}

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    nonisolated func open() { Task { await release() } }
    private func release() {
        opened = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
