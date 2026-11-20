import Foundation

/// The gate of a `fix: pr` task (docs/spec/tasks.md, "The gate"): before any thread exists, a read-only agent decides for the next
/// candidate units whether they can be done now. Gated units are held; the batch is topped up with further candidates; the worker then
/// runs on the clear ones alone. Nothing here touches git or starts a thread, so a run that dies in the gate has taken no unit.
extension TaskRunner {
    enum GateEnd {
        /// The units the worker takes (at most `batch`, in the script's order).
        case proceed([TaskUnit])
        case end(TaskRunResult)
    }

    /// Why the gate stopped asking, when the batch is not full.
    enum GateStop: String {
        case full
        case exhausted = "the pending list has no more candidates"
        case rounds = "the round limit (gate_rounds) was reached"
        case budget = "the run's budget leaves no room for another gate turn"
    }

    /// A unit the script no longer names (its version moved on, or its work was merged) is forgotten: a held unit leaves the list. Done
    /// before anything else about the run, so it happens when no candidate is left too. Nil when it worked, else why not.
    func forgetUnlisted(history: TaskHistory, listed: Set<String>, writer: EventLogWriter) async -> String? {
        for id in history.held.map(\.id) + history.cleared.sorted() where !listed.contains(id) {
            do { try await writer.append(.taskUnitReleased, data: ["unit": .string(id), "why": "no longer listed"]) } catch {
                return "the gate could not record that \(id) is no longer listed: \(error)"
            }
        }
        return nil
    }

    /// The units this run takes: the script's, less what is done or held, at most `batch`; with a gate, the ones it clears. A task with no
    /// script has one unit, the run itself, and no batching.
    func chooseUnits(name: String, loaded: LoadedTask, history: TaskHistory, writer: EventLogWriter) async -> GateEnd {
        let task = loaded.definition
        guard let script = task.pending else { return .proceed([]) }
        let all: [TaskUnit]
        do {
            all = try await PendingUnits.run(script: script, project: project, environment: environment)
        } catch { return .end(fail("\(error)")) }
        if task.gate != nil, !dryRun {
            let listed = Set(all.map(\.id))
            if let why = await forgetUnlisted(history: history, listed: listed, writer: writer) { return .end(fail(why)) }
        }
        let states = await TaskPullRequests.states(units: history.unitsWithThreads, gh: gh, project: project)
        // With a gate every candidate is in play, and the gate fills the batch from them; the held ones are already out.
        let batch = task.gate == nil ? task.batch : all.count
        let units = PendingUnits.select(units: all, history: history, pullRequests: states, batch: batch)
        if units.isEmpty {
            let held = history.held.isEmpty ? "" : " (\(history.held.count) held by the gate: workbench task held \(name))"
            return .end(TaskRunResult(outcome: .nothingPending, reason: "\(all.count) unit(s) listed, none left to do\(held)"))
        }
        guard task.gate != nil else { return .proceed(units) }
        return await runGate(name: name, loaded: loaded, queue: units, history: history, writer: writer)
    }

    private func runGate(
        name: String, loaded: LoadedTask, queue: [TaskUnit], history: TaskHistory, writer: EventLogWriter
    ) async -> GateEnd {
        let task = loaded.definition
        guard let gate = task.gate else { return .proceed(Array(queue.prefix(task.batch))) }
        let criteria = String(decoding: loaded.gateText ?? Data(), as: UTF8.self)
        let config: Config
        do { config = try Config.load(from: project.configURL) } catch {
            return .end(fail("the project's config cannot be read: \(error)"))
        }
        if !dryRun, config.checkCommand == nil {
            return .end(fail("no check configured: set check_command in .workbench/config.toml, so the work is checked"))
        }
        // Only Claude can be held to a tool list and a dollar cap: Codex's read-only sandbox may run any command and has no cap.
        let agent = config.resolvedJudgeAgent(modelFlag: nil)
        if agent.provider != .claude {
            let why = "[agents.judge] is \(agent.provider), which cannot be held to a tool list"
            return .end(fail("a gate needs Claude as its agent: \(why)"))
        }
        // The worker's turn is capped by `budget` alone, so a run budget below it could not be kept.
        let workerBudget = task.budgetUSD ?? config.defaultBudgetUSD
        if let cap = task.runBudgetUSD, cap < workerBudget {
            let spend = NSDecimalNumber(decimal: workerBudget).stringValue
            let capText = NSDecimalNumber(decimal: cap).stringValue
            return .end(fail("run_budget \(capText) is less than the worker's budget \(spend): raise it"))
        }
        let environment = runOptions.parentEnvironment
        let chosen: any ReadOnlyAgent
        if let given = readOnlyAgent {
            chosen = given
        } else {
            let cap = TaskGate.turnBudgetUSD
            switch ThreadService.readOnlyAgent(role: .judge, agent: agent, config: config, cap: cap, environment: environment) {
            case .success(let found): chosen = found
            case .failure(let refusal): return .end(fail(refusal.message))
            }
        }
        if let why = chosen.unavailable() { return .end(fail(why)) }
        if let why = await freshBase(task) { return .end(fail(why)) }

        // The gate reads the base as committed, in a checkout of its own, as a report turn does.
        let service = ThreadService(project: project, git: git)
        let baseName: String
        if let base = task.base { baseName = base } else { baseName = await service.defaultBase() }
        let manager = WorktreeManager(repoRoot: project.root, git: git)
        let commit: String
        do { commit = try await manager.commit(of: baseName) } catch {
            return .end(fail("the base \(baseName) cannot be read: \(error)"))
        }

        // What the whole run may spend, less what the worker's turns may: the rest is the gate's.
        let allowance =
            task.runBudgetUSD.map { max($0 - workerBudget, 0) } ?? TaskGate.turnBudgetUSD * Decimal(gate.effectiveRounds)
        var spent: Decimal = 0
        var clear: [TaskUnit] = []
        var held: [(unit: TaskUnit, reason: String)] = []
        var decided = Set<String>()
        var round = 0
        var stop = GateStop.full
        while true {
            // Units cleared in an earlier run are not asked about again: their id carries the version they were cleared at.
            for unit in queue where clear.count < task.batch && !decided.contains(unit.id) && history.cleared.contains(unit.id) {
                clear.append(unit)
                decided.insert(unit.id)
            }
            if clear.count >= task.batch { break }
            let candidates = Array(queue.filter { !decided.contains($0.id) }.prefix(task.batch - clear.count))
            if candidates.isEmpty { stop = .exhausted; break }
            if round >= gate.effectiveRounds { stop = .rounds; break }
            if allowance - spent <= 0 { stop = .budget; break }
            round += 1
            notice("gate round \(round): asking about \(candidates.map(\.id).joined(separator: ", "))")
            let asked = await askGate(
                name: name, criteria: criteria, candidates: candidates, gate: gate, agent: agent, chosen: chosen,
                manager: manager, commit: commit, budget: min(TaskGate.turnBudgetUSD, allowance - spent))
            guard let result = asked.answer else {
                return .end(fail("the gate could not decide: \(asked.failure ?? "no answer")", units: candidates.map(\.id)))
            }
            // A cost the agent did not report is taken as the most the turn could have cost.
            spent += asked.cost.map { Decimal($0) } ?? min(TaskGate.turnBudgetUSD, allowance - spent)
            let verdict = result.verdict
            var clearIDs: [String] = []
            var gatedList: [JSONValue] = []
            for answer in verdict.units {
                guard let unit = candidates.first(where: { $0.id == answer.id }) else { continue }
                decided.insert(unit.id)
                if answer.clear {
                    clear.append(unit)
                    clearIDs.append(unit.id)
                    notice("gate: \(unit.id) clear: \(answer.reason)")
                } else {
                    held.append((unit, answer.reason))
                    gatedList.append(.object(["unit": .string(unit.id), "reason": .string(answer.reason)]))
                    notice("gate: \(unit.id) held: \(answer.reason)")
                }
            }
            if dryRun { continue }
            // The verdicts are on record before any thread exists: a unit is never both held and taken.
            do {
                for answer in verdict.units {
                    guard let unit = candidates.first(where: { $0.id == answer.id }) else { continue }
                    let fields: [String: JSONValue] = [
                        "unit": .string(unit.id), "title": .string(unit.title), "reason": .string(answer.reason),
                        "round": .int(round),
                    ]
                    try await writer.append(answer.clear ? .taskUnitCleared : .taskUnitHeld, data: .object(fields))
                }
                var record: [String: JSONValue] = [
                    "round": .int(round), "candidates": .array(candidates.map { .string($0.id) }),
                    "clear": .array(clearIDs.map { .string($0) }), "gated": .array(gatedList),
                    "concerns": .array(verdict.concerns.map { .string($0) }),
                ]
                if let cost = asked.cost { record["cost_usd"] = .double(cost) }
                try await writer.append(.taskRunGate, data: .object(record))
            } catch {
                return .end(fail("the gate's verdicts could not be recorded, so nothing was started: \(error)"))
            }
        }
        if stop != .full { notice("gate stopped: \(stop.rawValue)") }
        let ids = clear.map(\.id)
        let heldText = held.map { "\($0.unit.id) (\($0.reason))" }.joined(separator: "; ")
        if dryRun {
            let taking = ids.isEmpty ? "would take nothing" : "would take " + ids.joined(separator: ", ")
            return .end(
                TaskRunResult(
                    outcome: .reported, reason: "dry run (gate): \(taking)" + (held.isEmpty ? "" : "; held: \(heldText)"),
                    units: ids))
        }
        guard !clear.isEmpty else {
            return .end(
                TaskRunResult(
                    outcome: .nothingToDo,
                    reason: "the gate held every candidate it asked about: \(heldText)"
                        + (stop == .full ? "" : "; it stopped because \(stop.rawValue)")))
        }
        return .proceed(clear)
    }

    struct GateAnswer {
        var verdict: TaskGateVerdict
    }

    /// What a gate turn came to: a verdict, or why there is none. The cost is known when the agent reported one, also after a
    /// failure (an answer that was not usable was still paid for).
    struct GateResult {
        var answer: GateAnswer?
        var failure: String?
        var cost: Double?

        init(answer: GateAnswer, cost: Double?) {
            (self.answer, self.cost) = (answer, cost)
        }

        init(failure: String, cost: Double? = nil) {
            (self.failure, self.cost) = (failure, cost)
        }
    }

    /// One gate turn on the base as committed. A failure says why, and nothing was started that outlives the turn.
    private func askGate(
        name: String, criteria: String, candidates: [TaskUnit], gate: TaskGate, agent: ResolvedAgent, chosen: any ReadOnlyAgent,
        manager: WorktreeManager, commit: String, budget: Decimal
    ) async -> GateResult {
        let folder = project.taskDirectory(name).appendingPathComponent("gate", isDirectory: true)
        let checkout = folder.appendingPathComponent("checkout", isDirectory: true)
        let key = Plan.sha256(folder.standardizedFileURL.path).prefix(16)
        let scratch = TurnScratch(url: FileManager.default.temporaryDirectory.appendingPathComponent("workbench-gate-\(key)"))
        var request = ReadOnlyRequest(
            prompt: TaskGateCheck.prompt(criteria: criteria, units: candidates), workingDirectory: checkout, model: agent.model,
            budget: budget, timeout: TaskGate.timeout, reasoningEffort: agent.reasoningEffort, tools: .read, scratch: scratch,
            turn: "gate")
        request.bash = gate.allow

        OrphanSweeper.sweep(inside: folder)
        await manager.removeDetached(at: checkout)
        scratch.clear()
        let stop = self.stop
        let answer: ReadOnlyAnswer
        do {
            try await manager.addDetached(at: checkout, commit: commit)
            answer = await chosen.run(request, attach: { stop.attach(process: $0) })
        } catch {
            OrphanSweeper.sweep(inside: folder)
            scratch.clear()
            await manager.removeDetached(at: checkout)
            return GateResult(failure: "the base could not be checked out for the gate: \(error)")
        }
        OrphanSweeper.sweep(inside: folder)
        scratch.clear()
        await manager.removeDetached(at: checkout)

        guard let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return GateResult(failure: answer.failure ?? "the agent gave no answer", cost: answer.costUSD)
        }
        do {
            return GateResult(
                answer: GateAnswer(verdict: try TaskGateCheck.verdict(fromAnswer: text, units: candidates)),
                cost: answer.costUSD)
        } catch { return GateResult(failure: "\(error)", cost: answer.costUSD) }
    }
}
