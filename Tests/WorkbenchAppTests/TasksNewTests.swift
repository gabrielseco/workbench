import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// The New task screen: the name checked as it is typed, a proposal accepted or discarded, and the empty task with no agent.
@MainActor private var keptNewFixtures: [AppFixture] = []

@MainActor @Suite struct TasksNewTests {
    private let proposal = TaskProposal(
        task: "todo-report", text: "---\nat: 09:00\nfix: report\n---\nReport the TODOs.\n",
        changes: TaskChanges(
            settings: [TaskSettingChange(key: "fix", old: nil, new: "report")],
            instructions: [TaskDiffLine(kind: .added, text: "Report the TODOs.")]),
        source: "", isNew: true)

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String] = []
        private var accepted: [TaskProposal] = []
        var asked: [String] { lock.withLock { made } }
        var accepts: [TaskProposal] { lock.withLock { accepted } }
        func ask(_ name: String) { lock.withLock { made.append(name) } }
        func accept(_ proposal: TaskProposal) { lock.withLock { accepted.append(proposal) } }
    }

    private let calls = Calls()

    private func scenario(
        proposeNew: TaskActions.Edit? = nil, accept: (@Sendable (Project, TaskProposal) async throws -> Void)? = nil
    ) async throws -> (AppFixture, TasksModel) {
        let fixture = try await AppFixture(git: false)
        try await AppScenario.tasks.build(in: fixture)
        let env = [
            "WORKBENCH_APP_HOME": fixture.root.appendingPathComponent("home").path,
            "WORKBENCH_APP_LAUNCHCTL": "/nonexistent/launchctl",
        ]
        let calls = self.calls
        let shown = proposal
        var actions = TaskActions(
            inspect: TaskActions.core.inspect, approve: TaskActions.core.approve, run: TaskActions.core.run)
        actions.proposeNew = proposeNew ?? { _, name, _, _ in
            calls.ask(name)
            return TaskEditResult(proposal: shown, provider: .codex, costUSD: 0.0123)
        }
        actions.acceptEdit = accept ?? { _, proposal in calls.accept(proposal) }
        let tasks = TasksModel(reader: .core(environment: env), actions: actions)
        await tasks.refresh(fixture.project)
        return (fixture, tasks)
    }

    @Test func theNameIsCheckedAsTyped() async throws {
        let (fixture, tasks) = try await scenario()
        let project = fixture.project
        #expect(tasks.nameCheck("", in: project) == .empty && tasks.nameCheck("  ", in: project) == .empty)
        #expect(tasks.nameCheck("has space", in: project) == .invalid && tasks.nameCheck("../x", in: project) == .invalid)
        #expect(tasks.nameCheck("a/b", in: project) == .invalid && tasks.nameCheck(".hidden", in: project) == .invalid)
        #expect(tasks.nameCheck("update-docs", in: project) == .taken, "a task in the list")
        #expect(tasks.nameCheck("brand-new", in: project) == .ok && tasks.nameCheck(" brand-new ", in: project) == .ok)
        // A folder that is there but not yet in the list (made a moment ago) is taken too.
        try FileManager.default.createDirectory(at: project.taskDirectory("just-made"), withIntermediateDirectories: true)
        #expect(tasks.nameCheck("just-made", in: project) == .taken)
        #expect(TaskNameCheck.invalid.message != nil && TaskNameCheck.taken.message != nil && TaskNameCheck.ok.message == nil)

        // Propose is off until the name and the words are good, and says which is missing.
        tasks.beginNew(fixture.project)
        #expect(tasks.proposeNewUnavailable(in: project)?.contains("Name the task") == true)
        tasks.creating?.name = "has space"
        #expect(tasks.proposeNewUnavailable(in: project)?.contains("cannot be used") == true)
        tasks.creating?.name = "brand-new"
        #expect(tasks.proposeNewUnavailable(in: project)?.contains("what the task should do") == true)
        tasks.creating?.request = "report the TODOs"
        #expect(tasks.proposeNewUnavailable(in: project)?.contains("goal agent") == true, "no [agents.goal] in the fixture")
        await tasks.proposeNew(project)
        #expect(calls.asked.isEmpty && tasks.creating?.phase == .idle, "nothing is asked when it is off")
    }

    /// A project config that loads (the tools table is required) and names the goal agent.
    private static func config(goal: String, extra: String = "") -> String {
        "default_budget_usd = 3\n\n[tools]\navailable = [\"Read\"]\n\n[agents.goal]\nprovider = \"\(goal)\"\n\(extra)"
    }

    private func withGoalAgent(_ fixture: AppFixture, _ tasks: TasksModel) async throws {
        try Self.config(goal: "codex", extra: "allow_unpriced = true\n")
            .write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        await tasks.refresh(fixture.project)
    }

    @Test func acceptCreatesAndSelects() async throws {
        let (fixture, tasks) = try await scenario()
        try await withGoalAgent(fixture, tasks)
        tasks.beginNew(fixture.project)
        tasks.creating?.name = "todo-report"
        tasks.creating?.request = "  report the TODOs every weekday at 9 \n"
        #expect(tasks.proposeNewUnavailable(in: fixture.project) == nil)
        await tasks.proposeNew(fixture.project)
        #expect(calls.asked == ["todo-report"])
        #expect(tasks.creating?.phase == .proposed(proposal, cost: "$0.0123"))
        #expect(calls.accepts.isEmpty, "a proposal creates nothing")
        let made = await tasks.acceptNew(fixture.project)
        #expect(made == "todo-report" && calls.accepts == [proposal])
        #expect(tasks.creating == nil, "the screen is put away")
        // Nothing to accept when there is no proposal: no call.
        #expect(await tasks.acceptNew(fixture.project) == nil && calls.accepts.count == 1)
    }

    @Test func discardKeepsTheWords() async throws {
        let (fixture, tasks) = try await scenario()
        try await withGoalAgent(fixture, tasks)
        tasks.beginNew(fixture.project)
        tasks.creating?.name = "todo-report"
        tasks.creating?.request = "report the TODOs"
        await tasks.proposeNew(fixture.project)
        tasks.discardNew()
        let words = NewTaskDraft(
            project: fixture.project.root.path, name: "todo-report", request: "report the TODOs", phase: .idle)
        #expect(tasks.creating == words)
        // Cancel puts the screen away; it is refused while the agent works.
        tasks.cancelNew()
        #expect(tasks.creating == nil)
    }

    @Test func aFailureOrARefusedAcceptIsSaidAndCreatesNothing() async throws {
        let (fixture, failing) = try await scenario(
            proposeNew: { _, _, _, _ in
                TaskEditResult(proposal: nil, provider: .codex, costUSD: 0.01, failure: "not usable: no result")
            },
            accept: { _, _ in throw TaskEditRefusal.taskExists("todo-report") })
        try await withGoalAgent(fixture, failing)
        failing.beginNew(fixture.project)
        failing.creating?.name = "todo-report"
        failing.creating?.request = "x"
        await failing.proposeNew(fixture.project)
        guard case .failed(let why)? = failing.creating?.phase else {
            Issue.record("not failed")
            return
        }
        #expect(why.contains("not usable") && why.contains("Nothing was created") && why.contains("$0.0100"), "\(why)")
        // An accept the core refuses (the name was taken meanwhile) stays on the screen with the core's words.
        let (fixture2, refusing) = try await scenario(accept: { _, _ in throw TaskEditRefusal.taskExists("todo-report") })
        try await withGoalAgent(fixture2, refusing)
        refusing.beginNew(fixture2.project)
        refusing.creating?.name = "todo-report"
        refusing.creating?.request = "x"
        await refusing.proposeNew(fixture2.project)
        #expect(await refusing.acceptNew(fixture2.project) == nil)
        guard case .failed(let said)? = refusing.creating?.phase else {
            Issue.record("accept did not fail")
            return
        }
        #expect(said.contains("exists already"), "\(said)")
    }

    @Test func createEmptyNeedsNoAgent() async throws {
        let (fixture, tasks) = try await scenario(proposeNew: { _, _, _, _ in
            Issue.record("the agent was asked")
            return TaskEditResult(proposal: nil, provider: .codex)
        })
        // The fixture has no [agents.goal] at all: the empty task is the way through.
        tasks.beginNew(fixture.project)
        tasks.creating?.name = "by-hand"
        #expect(await tasks.createEmpty(fixture.project) == "by-hand")
        #expect(tasks.creating == nil)
        let text = try String(contentsOf: fixture.project.taskFileURL("by-hand"), encoding: .utf8)
        #expect(text.contains("fix: report") && text.contains(TaskScaffold.placeholder), "what `task new` makes")
        let script = fixture.project.taskDirectory("by-hand").appendingPathComponent("pending.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(tasks.snapshot?.entries.contains { $0.id == "by-hand" } == true, "the list was read again")
        // The same name twice, a bad name and an empty one create nothing.
        tasks.beginNew(fixture.project)
        tasks.creating?.name = "by-hand"
        #expect(await tasks.createEmpty(fixture.project) == nil)
        tasks.creating?.name = "bad name"
        #expect(await tasks.createEmpty(fixture.project) == nil)
        tasks.creating?.name = ""
        #expect(await tasks.createEmpty(fixture.project) == nil)
    }

    @Test func theLimitIsSaidPerProvider() async throws {
        let (fixture, tasks) = try await scenario()
        #expect(tasks.editLimit == nil, "no goal agent: the screen says Propose needs one")
        try Self.config(goal: "codex", extra: "allow_unpriced = true\n")
            .write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        await tasks.refresh(fixture.project)
        #expect(tasks.editLimit == "no dollar cap: bounded by 5 min")
        try Self.config(goal: "claude").write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        await tasks.refresh(fixture.project)
        #expect(tasks.editLimit == "up to $0.50")
    }

    @Test func aProposalIsOnlyAcceptedInTheProjectItWasMadeFor() async throws {
        let (fixture, tasks) = try await scenario()
        let (other, _) = try await scenario()
        try await withGoalAgent(fixture, tasks)
        tasks.beginNew(fixture.project)
        tasks.creating?.name = "todo-report"
        tasks.creating?.request = "report the TODOs"
        await tasks.proposeNew(fixture.project)
        #expect(tasks.creating?.project == fixture.project.root.path)
        // Another project is on screen now: it does not see this draft, and nothing can be accepted or created into it.
        #expect(tasks.draft(in: other.project) == nil && !tasks.isNewShown(in: other.project))
        #expect(await tasks.acceptNew(other.project) == nil && calls.accepts.isEmpty)
        #expect(await tasks.createEmpty(other.project) == nil)
        #expect(!FileManager.default.fileExists(atPath: other.project.taskDirectory("todo-report").path))
        await tasks.proposeNew(other.project)
        #expect(calls.asked == ["todo-report"], "asked once, for the project it was begun in")
        // Opening the screen in the other project starts its own draft rather than carrying the words over.
        tasks.beginNew(other.project)
        #expect(tasks.creating == NewTaskDraft(project: other.project.root.path))
        #expect(await tasks.acceptNew(fixture.project) == nil, "the first project's proposal is gone with its draft")
    }

    @Test func oneAgentAtATimeAcrossEditAndNew() async throws {
        let (fixture, tasks) = try await scenario()
        try await withGoalAgent(fixture, tasks)
        tasks.beginNew(fixture.project)
        tasks.creating?.name = "todo-report"
        tasks.creating?.request = "x"
        let entry = try #require(tasks.snapshot?.entries.first { $0.id == "update-docs" })
        // An edit is with the agent: Propose for a new task waits.
        tasks.editing = TaskEditing(project: fixture.project.root.path, task: entry.id, phase: .working)
        #expect(tasks.proposeNewUnavailable(in: fixture.project)?.contains("one at a time") == true)
        tasks.editing = nil
        #expect(tasks.proposeNewUnavailable(in: fixture.project) == nil)
        // A new task is with the agent: Propose for an edit waits.
        tasks.creating?.phase = .working
        #expect(tasks.editUnavailable(entry)?.contains("one at a time") == true)
        tasks.editRequest = "y"
        await tasks.proposeEdit(fixture.project, entry)
        #expect(tasks.editing == nil && calls.asked.isEmpty, "no second agent was started")
    }

    @Test func aRequestTheCoreWouldRefuseKeepsProposeOff() async throws {
        let (fixture, tasks) = try await scenario()
        try await withGoalAgent(fixture, tasks)
        tasks.beginNew(fixture.project)
        tasks.creating?.name = "todo-report"
        tasks.creating?.request = String(repeating: "x", count: TaskEdit.requestLimit + 1)
        #expect(tasks.proposeNewUnavailable(in: fixture.project)?.contains("over 16 KiB") == true)
        tasks.creating?.request = "has a nul \0"
        #expect(tasks.proposeNewUnavailable(in: fixture.project)?.contains("control character") == true)
        tasks.creating?.request = "fine"
        #expect(tasks.proposeNewUnavailable(in: fixture.project) == nil)
        let atTheLimit = String(repeating: "x", count: TaskEdit.requestLimit)
        #expect(TaskEdit.requestProblem(atTheLimit) == nil, "the limit itself is allowed")
    }

    @Test func choosingATaskLeavesTheScreenAndKeepsTheDraft() async throws {
        let fixture = try await AppFixture()
        keptNewFixtures.append(fixture)
        try await AppScenario.tasks.build(in: fixture)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: GoalActions())
        #expect(await store.open(fixture.root))
        store.beginNewTask()
        store.tasks.creating?.name = "half-typed"
        #expect(store.tasks.isNewShown(in: store.project) && store.mode == .tasks)
        store.selectTask("update-docs")
        #expect(!store.tasks.isNewShown(in: store.project), "the chosen task's page is what shows")
        #expect(store.tasks.selection == "update-docs", "the chosen task is selected")
        #expect(store.tasks.creating?.name == "half-typed", "the words are kept")
        store.beginNewTask()
        #expect(store.tasks.isNewShown(in: store.project) && store.tasks.creating?.name == "half-typed", "and brought back")
    }
}
