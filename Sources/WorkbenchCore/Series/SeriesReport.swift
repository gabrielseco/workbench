import Foundation

/// One finding of a review round, as its findings file lists it: `- **[P1] title.** …`.
public struct SeriesReportFinding: Sendable, Equatable {
    public var severity: String
    public var title: String
}

/// The follow-up thread that answered one review round.
public struct SeriesReportFix: Sendable, Equatable {
    public var thread: String
    public var costUSD: Double
    public var costUnknown: Bool
    public var turns: Int
    /// Subjects of the commits it made on the branch; empty when its branch is gone.
    public var commits: [String]
    /// What the agent said last: what it fixed and what it left, in its own words.
    public var said: String?
}

public struct SeriesReportRound: Sendable, Equatable {
    public var round: Int
    /// `clean`, `fix`, or nil when the round recorded no verdict.
    public var verdict: String?
    public var findings: [SeriesReportFinding]
    /// Where the round's whole answer is kept (inside the thread's folder).
    public var findingsFile: String?
    public var fix: SeriesReportFix?
}

public struct SeriesReportCriterion: Sendable, Equatable {
    public var id: String
    public var text: String
    /// The judge's reading; nil when it gave none.
    public var met: Bool?
}

public struct SeriesReportStep: Sendable, Equatable {
    public var number: Int
    public var project: String
    public var goalTitle: String
    public var state: SeriesStepState
    public var thread: String?
    public var pullRequest: String?
    public var additions: Int?
    public var deletions: Int?
    public var files: [String]
    public var turns: Int
    public var costUSD: Double
    /// A turn of the step did not report a cost (a provider with no dollar figure), so `costUSD` is a lower bound.
    public var costUnknown: Bool
    public var check: String?
    public var verifier: String?
    public var criteria: [SeriesReportCriterion]
    public var judgeConcerns: [String]
    /// The turn the judge's reading is of: later turns (the review follow-ups) may have fixed what it found.
    public var judgeTurn: Int?
    public var built: String?
    public var rounds: [SeriesReportRound]
    /// Threads made by hand on this step's pull request branch (`goal new --update`), outside the review loop.
    public var manual: [SeriesReportFix]
}

public struct SeriesReport: Sendable, Equatable {
    public var name: String
    public var generated: String
    public var budgetUSD: Double?
    public var steps: [SeriesReportStep]

    public var totalCostUSD: Double { steps.reduce(0) { $0 + $1.costUSD } }
    public var totalCostUnknown: Bool { steps.contains { $0.costUnknown } }
}

/// Builds the report of a series from what is already recorded: the steps' thread logs, their review rounds and follow-up threads, and
/// (when `gh` is there) each pull request's size. Nothing is run and nothing is changed.
public struct SeriesReporter: Sendable {
    public let library: SeriesLibrary
    public var git: GitRunner
    public var gh: GitRunner?
    public var now: @Sendable () -> Date = { Date() }

    public init(library: SeriesLibrary, git: GitRunner, gh: GitRunner?) {
        self.library = library
        self.git = git
        self.gh = gh
    }

    public func report(_ name: String) async throws -> SeriesReport {
        let loaded = try library.load(name)
        let states = await library.states(loaded, git: git, gh: gh)
        let records = SeriesStepLog(project: library.project, series: name).read()
        var steps: [SeriesReportStep] = []
        for step in loaded.definition.steps {
            let title = loaded.goals[step.number]?.title ?? step.goal
            guard let record = records[step.number], let root = loaded.projects[step.number] else {
                steps.append(Self.notStarted(step, title: title, project: loaded.projects[step.number]))
                continue
            }
            steps.append(
                await collect(
                    step, title: title, root: root, thread: record.thread, state: states[step.number] ?? .pending))
        }
        let stamp = ISO8601DateFormatter().string(from: now())
        let budget = loaded.definition.budgetUSD.map { NSDecimalNumber(decimal: $0).doubleValue }
        return SeriesReport(name: name, generated: stamp, budgetUSD: budget, steps: steps)
    }

    private static func notStarted(_ step: SeriesStep, title: String, project: URL?) -> SeriesReportStep {
        SeriesReportStep(
            number: step.number, project: project?.path ?? step.project, goalTitle: title, state: .pending, thread: nil,
            pullRequest: nil, additions: nil, deletions: nil, files: [], turns: 0, costUSD: 0, costUnknown: false, check: nil,
            verifier: nil,
            criteria: [], judgeConcerns: [], judgeTurn: nil, built: nil, rounds: [], manual: [])
    }

    private func collect(
        _ step: SeriesStep, title: String, root: URL, thread: String, state: SeriesStepState
    ) async -> SeriesReportStep {
        let project = Project(root: root)
        let store = ThreadStore(project: project)
        let service = ThreadService(project: project, git: git)
        let rootState = store.state(of: thread)
        let followUps = store.followUps(of: thread)
        let family = [thread] + followUps.map(\.id)
        // Threads someone made on the same branch by hand are part of what happened to this pull request.
        let branch = SeriesRebaser.branch(project: project, thread: thread)
        var manual: [SeriesReportFix] = []
        for other in store.summaries().map(\.id).sorted() where !family.contains(other) {
            let text = try? String(contentsOf: project.goalURL(other), encoding: .utf8)
            guard let text, (try? GoalFile.parse(text).goal.pushTo) == branch else { continue }
            manual.append(await fix(store.state(of: other), project: project))
        }
        // Hand-made threads are not in the family, so their turns and cost are added here; a CI fix is in the family and counted below.
        let manualTurns = manual.reduce(0) { $0 + $1.turns }
        var cost = manual.reduce(0) { $0 + $1.costUSD }
        var unknown = manual.contains { $0.costUnknown }
        for member in family {
            let memberState = store.state(of: member)
            cost += memberState.totalCostUSD
            unknown = unknown || memberState.costUnknown
        }
        // Which review round each follow-up answers is what its own goal says (`ReviewLoop.body` writes "(review round N)" into the
        // request): the loop's round counter also counts the follow-ups that fix CI, so it cannot be used. A goal that cannot be
        // read falls back to that counter.
        var answers: [String: Int] = [:]
        for follow in followUps {
            let text = try? String(contentsOf: project.goalURL(follow.id), encoding: .utf8)
            if let text {
                if let round = Self.reviewRound(in: text) { answers[follow.id] = round }
            } else if let round = follow.lineage?.round {
                answers[follow.id] = round
            }
        }
        // A follow-up that answers no review round (a CI fix) belongs with the work done outside the review rounds.
        for follow in followUps where answers[follow.id] == nil { manual.append(await fix(follow, project: project)) }

        let goal = (try? String(contentsOf: project.goalURL(thread), encoding: .utf8)).flatMap { try? GoalFile.parse($0).goal }
        let verdict = rootState.review.judge?.verdict
        let criteria = (goal?.criteria ?? []).map { criterion in
            SeriesReportCriterion(
                id: criterion.id, text: criterion.text, met: verdict?.criteria.first { $0.id == criterion.id }?.met)
        }
        var rounds: [SeriesReportRound] = []
        if let pr = rootState.pullRequest?.number {
            for record in service.reviewRecords(.prReview, family: family, pr: pr) {
                let text = service.prReviewFindings(record)
                var answer: SeriesReportFix?
                if let followUp = followUps.first(where: { answers[$0.id] == record.round }) {
                    answer = await fix(followUp, project: project)
                }
                rounds.append(
                    SeriesReportRound(
                        round: record.round, verdict: record.verdict?.rawValue, findings: Self.findings(in: text),
                        findingsFile: record.findingsPath.map { ".workbench/threads/\(record.thread)/\($0)" },
                        fix: answer))
            }
        }
        let live = await livePullRequest(rootState.pullRequest?.number, root: root)
        return SeriesReportStep(
            number: step.number, project: root.path, goalTitle: title, state: state, thread: thread,
            pullRequest: rootState.pullRequest?.url, additions: live?.additions, deletions: live?.deletions,
            files: live?.files ?? [], turns: rootState.lastTurn + followUps.reduce(0) { $0 + $1.lastTurn } + manualTurns,
            costUSD: cost,
            costUnknown: unknown,
            check: rootState.review.check.map { "\($0.result) after turn \($0.turn)" },
            verifier: rootState.review.verifier.flatMap { $0.skipped ? nil : ($0.ok ? "passed" : "did not pass") },
            criteria: criteria, judgeConcerns: verdict?.concerns ?? [], judgeTurn: rootState.review.judge?.turn,
            built: TaskLogReport.lastAgentText(project: project, thread: thread, events: nil), rounds: rounds,
            manual: manual)
    }

    private func fix(_ state: ThreadState, project: Project) async -> SeriesReportFix {
        var commits: [String] = []
        let events = (try? EventLogReader.read(at: project.eventsURL(state.id)))?.events ?? []
        let cut = events.last { $0.kind == .worktreeCreated }?.data["base_commit"]?.stringValue
        if let cut, SafeNames.isCommitSHA(cut) {
            let branch = WorktreeManager.branch(for: state.id)
            let log = try? await git.run(["log", "--format=%s", "\(cut)..refs/heads/\(branch)"], in: project.root)
            if log?.succeeded == true {
                commits = log?.stdout.split(separator: "\n").map(String.init) ?? []
            }
        }
        return SeriesReportFix(
            thread: state.id, costUSD: state.totalCostUSD, costUnknown: state.costUnknown, turns: state.lastTurn,
            commits: commits,
            said: TaskLogReport.lastAgentText(project: project, thread: state.id, events: events))
    }

    /// The review round a follow-up's goal says it answers: `(review round 2)`, which `ReviewLoop.body` writes into the request.
    static func reviewRound(in goalText: String) -> Int? {
        goalText.firstMatch(of: #/\(review round ([0-9]+)\)/#).flatMap { Int($0.1) }
    }

    /// `- **[P1] A title.** the rest`: the severity and the title of each finding. A line that does not look like that is left out
    /// (the round's file has it whole).
    static func findings(in text: String?) -> [SeriesReportFinding] {
        guard let text else { return [] }
        var found: [SeriesReportFinding] = []
        for line in text.split(separator: "\n") {
            guard let match = line.firstMatch(of: #/^\s*[-*]\s+\*\*\[?(P[0-9])\]?\s*[—:–-]?\s*(.+?)\*\*/#) else { continue }
            let title = String(match.2).trimmingCharacters(in: CharacterSet(charactersIn: " .—:"))
            found.append(SeriesReportFinding(severity: String(match.1), title: title))
        }
        return found
    }

    private struct LivePR {
        var additions: Int
        var deletions: Int
        var files: [String]
    }

    private func livePullRequest(_ number: Int?, root: URL) async -> LivePR? {
        guard let number, let gh else { return nil }
        var environment = gh.environment
        environment["GH_REPO"] = nil
        let reader = GitRunner(executable: gh.executable, environment: environment, timeout: ThreadService.prTimeout)
        guard let result = try? await reader.run(
            ["pr", "view", String(number), "--json", "additions,deletions,files"], in: root), result.succeeded,
            let data = result.stdout.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let files = (json["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        return LivePR(additions: json["additions"] as? Int ?? 0, deletions: json["deletions"] as? Int ?? 0, files: files)
    }
}
