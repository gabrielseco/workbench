import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor @Suite struct TasksEditTests {
    private let calls = Calls()
    private let proposal = TaskProposal(
        task: "cleanup-branches", text: "---\nfix: report\nbudget: 3\n---\nDo.\n",
        changes: TaskChanges(
            settings: [TaskSettingChange(key: "budget", old: nil, new: "3")],
            instructions: [TaskDiffLine(kind: .same, text: "Do.")]),
        source: "---\nfix: report\n---\nDo.\n")

    /// What the model asked the agent, and what it was told to accept.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        private var accepted: [TaskProposal] = []
        var requests: [String] { lock.withLock { asked } }
        var accepts: [TaskProposal] { lock.withLock { accepted } }
        func ask(_ request: String) { lock.withLock { asked.append(request) } }
        func accept(_ proposal: TaskProposal) { lock.withLock { accepted.append(proposal) } }
    }

    private func scenario() async throws -> (AppFixture, TasksModel) {
        let fixture = try await AppFixture(git: false)
        try await AppScenario.tasks.build(in: fixture)
        let env = [
            "WORKBENCH_APP_HOME": fixture.root.appendingPathComponent("home").path,
            "WORKBENCH_APP_LAUNCHCTL": "/nonexistent/launchctl",
        ]
        let calls = self.calls
        let actions = TaskActions(
            inspect: TaskActions.core.inspect, approve: TaskActions.core.approve, run: TaskActions.core.run,
            edit: { [proposal] _, _, request, _ in
                calls.ask(request)
                return TaskEditResult(proposal: proposal, provider: .codex, costUSD: 0.0123)
            },
            acceptEdit: { _, proposal in calls.accept(proposal) })
        let model = TasksModel(reader: .core(environment: env), actions: actions)
        await model.refresh(fixture.project)
        return (fixture, model)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "never: \(what)")
    }

    /// One thing the agent waits for and the test releases.
    private actor Gate {
        private var opened = false
        private var waiting: CheckedContinuation<Void, Never>?
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func open() {
            opened = true
            waiting?.resume()
            waiting = nil
        }
    }

    private func entry(_ model: TasksModel, _ name: String = "cleanup-branches") throws -> TaskEntry {
        let shown = try #require(model.snapshot)
        return try #require(shown.entries.first { $0.id == name })
    }

    @Test func editWithAI() async throws {
        let (fixture, tasks) = try await scenario()
        let entry = try entry(tasks)
        // Nothing is asked for an empty request.
        tasks.editRequest = "  \n"
        await tasks.proposeEdit(fixture.project, entry)
        #expect(calls.requests.isEmpty && tasks.editing == nil)

        tasks.editRequest = "  allow three dollars \n"
        await tasks.proposeEdit(fixture.project, entry)
        #expect(calls.requests == ["allow three dollars"], "the request is the person's words, trimmed")
        let shown = try #require(tasks.editing(entry.id, in: fixture.project))
        #expect(shown.phase == .proposed(proposal, cost: "$0.0123"))
        #expect(tasks.editing("update-docs", in: fixture.project) == nil, "another task shows no edit")
        #expect(calls.accepts.isEmpty, "a proposal writes nothing")

        await tasks.acceptEdit(fixture.project)
        #expect(calls.accepts == [proposal])
        #expect(tasks.editing == nil && tasks.editRequest.isEmpty)
    }

    @Test func discardKeepsTheRequestAndWritesNothing() async throws {
        let (fixture, tasks) = try await scenario()
        tasks.editRequest = "skip vendor"
        await tasks.proposeEdit(fixture.project, try entry(tasks))
        tasks.discardEdit()
        #expect(tasks.editing == nil && tasks.editRequest == "skip vendor" && calls.accepts.isEmpty)
    }

    @Test func aFailureOrARefusalIsShownWithTheCoresWords() async throws {
        let (fixture, _) = try await scenario()
        func model(_ edit: @escaping TaskActions.Edit) -> TasksModel {
            TasksModel(
                reader: .core(), actions: TaskActions(
                    inspect: TaskActions.core.inspect, approve: TaskActions.core.approve, run: TaskActions.core.run, edit: edit,
                    acceptEdit: { _, _ in throw TaskEditRefusal.changedMeanwhile }))
        }
        let failed = model { _, _, _, _ in
            TaskEditResult(proposal: nil, provider: .codex, costUSD: 0.01, failure: "the proposal was not usable: no result")
        }
        await failed.refresh(fixture.project)
        failed.editRequest = "x"
        await failed.proposeEdit(fixture.project, try entry(failed))
        guard case .failed(let why)? = failed.editing?.phase else {
            Issue.record("not failed")
            return
        }
        #expect(why.contains("not usable") && why.contains("Nothing was written") && why.contains("$0.0100"), "\(why)")

        let refused = model { _, _, _, _ in throw TaskEditRefusal.noGoalAgent }
        await refused.refresh(fixture.project)
        refused.editRequest = "x"
        await refused.proposeEdit(fixture.project, try entry(refused))
        guard case .failed(let reason)? = refused.editing?.phase else {
            Issue.record("not failed")
            return
        }
        #expect(reason.contains("[agents.goal]"), "\(reason)")

        // An accept the core refuses leaves nothing written and says why.
        let (_, tasks) = try await scenario()
        let stale = model { [proposal] _, _, _, _ in TaskEditResult(proposal: proposal, provider: .codex) }
        await stale.refresh(fixture.project)
        stale.editRequest = "x"
        await stale.proposeEdit(fixture.project, try entry(stale))
        await stale.acceptEdit(fixture.project)
        guard case .failed(let changed)? = stale.editing?.phase else {
            Issue.record("accept did not fail")
            return
        }
        #expect(changed.contains("changed after this proposal"), "\(changed)")
        _ = tasks
    }

    @Test func propositionsAreOneAtATimeAndStoppable() async throws {
        let (fixture, _) = try await scenario()
        let gate = Gate()
        let tasks = TasksModel(
            reader: .core(), actions: TaskActions(
                inspect: TaskActions.core.inspect, approve: TaskActions.core.approve, run: TaskActions.core.run,
                edit: { _, _, _, stop in
                    await gate.wait()
                    return TaskEditResult(
                        proposal: nil, provider: .codex, failure: stop.wasRequested ? "the draft was stopped" : "no result")
                }))
        await tasks.refresh(fixture.project)
        let entry = try entry(tasks)
        tasks.editRequest = "x"
        let running = Task { await tasks.proposeEdit(fixture.project, entry) }
        try await until("it is working") { tasks.editing?.phase == .working }
        #expect(tasks.editUnavailable(entry)?.contains("one at a time") == true)
        tasks.stopEdit()
        await gate.open()
        await running.value
        guard case .failed(let why)? = tasks.editing?.phase else {
            Issue.record("not failed")
            return
        }
        #expect(why.hasPrefix("Stopped."), "\(why)")
    }

    @Test func notOfferedForATaskThatDoesNotLoadOrIsRunning() async throws {
        let (fixture, tasks) = try await scenario()
        let broken = try entry(tasks, "broken-task")
        #expect(tasks.editUnavailable(broken)?.contains("does not load") == true)
        let running = try entry(tasks, "update-docs")
        tasks.runningTask = running.id
        #expect(tasks.editUnavailable(running)?.contains("run of this task") == true)
        tasks.editRequest = "x"
        await tasks.proposeEdit(fixture.project, running)
        #expect(tasks.editing == nil && tasks.actionNote != nil)
    }

    @Test func quittingEndsAnEditInProgress() async throws {
        #expect(QuitPrompt.work(threadRunIn: nil, taskRun: nil, editing: true) == "a task edit is still going.")
        let (fixture, _) = try await scenario()
        let gate = Gate()
        let stops = Calls()
        let actions = TaskActions(
            inspect: TaskActions.core.inspect, approve: TaskActions.core.approve, run: TaskActions.core.run,
            edit: { _, _, _, stop in
                stop.attach {
                    stops.ask("stopped")
                    Task { await gate.open() }
                }
                await gate.wait()
                return TaskEditResult(proposal: nil, provider: .codex, failure: "the draft was stopped")
            })
        let tasks = TasksModel(reader: .core(), actions: actions)
        await tasks.refresh(fixture.project)
        let entry = try entry(tasks)
        tasks.editRequest = "x"
        let running = Task { await tasks.proposeEdit(fixture.project, entry) }
        try await until("it is working") { tasks.isEditing }
        await tasks.stopEditAndWait(timeout: .seconds(3))
        #expect(stops.requests == ["stopped"] && !tasks.isEditing, "the agent was stopped and waited for")
        await running.value

        // The store's quit confirmation counts it, so a quit is not silent about an agent that is still spending.
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil), actions: GoalActions())
        #expect(store.liveWork == nil)
        store.tasks.editing = TaskEditing(project: fixture.project.root.path, task: entry.id, phase: .working)
        #expect(store.liveWork == "a task edit is still going.")
    }

    @Test func theCardIsClosedUntilTheButtonOpensIt() async throws {
        let (fixture, tasks) = try await scenario()
        let entry = try entry(tasks)
        #expect(!tasks.isEditShown(entry.id, in: fixture.project), "closed by default")
        tasks.toggleEdit(entry.id, in: fixture.project)
        #expect(tasks.isEditShown(entry.id, in: fixture.project))
        #expect(!tasks.isEditShown("update-docs", in: fixture.project), "another task's card stays closed")
        tasks.toggleEdit(entry.id, in: fixture.project)
        #expect(!tasks.isEditShown(entry.id, in: fixture.project), "the button closes it again")

        // A proposal is waiting: the card stays, and the button cannot close it under the person's decision.
        tasks.toggleEdit(entry.id, in: fixture.project)
        tasks.editRequest = "x"
        await tasks.proposeEdit(fixture.project, entry)
        tasks.toggleEdit(entry.id, in: fixture.project)
        #expect(tasks.isEditShown(entry.id, in: fixture.project) && tasks.editing(entry.id, in: fixture.project) != nil)
        // Accepting writes it and puts the card away; the next edit starts from a closed card.
        await tasks.acceptEdit(fixture.project)
        #expect(!tasks.isEditShown(entry.id, in: fixture.project))
        // Discarding leaves the card open on its text box.
        tasks.toggleEdit(entry.id, in: fixture.project)
        await tasks.proposeEdit(fixture.project, entry)
        tasks.discardEdit()
        #expect(tasks.isEditShown(entry.id, in: fixture.project))
    }
}
