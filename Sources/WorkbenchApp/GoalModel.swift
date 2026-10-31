import Foundation
import WorkbenchCore

/// What the Goal screen shows about one thread's goal file, read as the CLI reads it. Built off the main actor; the view
/// holds none of it.
struct GoalModel: Equatable {
    enum Pill: Equatable {
        case draft, approved, changedSinceApproval

        var text: String {
            switch self {
            case .draft: "Draft · not approved"
            case .approved: "Approved"
            case .changedSinceApproval: "Changed since approval"
            }
        }
    }

    struct Row: Equatable {
        var id: String
        var text: String
        var proof: String
        /// Why Workbench cannot check this proof; nil when it can.
        var warning: String?
        var suggestion: String?

        /// What kind of proof it is, for the chip: `test`, `screenshot`, `command` (a backticked command) or `by hand`.
        var isCommand: Bool { kind == "command" }

        var kind: String {
            let trimmed = proof.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("test:") { return "test" }
            if ScreenshotProof.name(in: proof) != nil { return "screenshot" }
            // A drafted goal writes `command: pnpm run lint`; a hand-written one may put the command in backticks.
            return lower.hasPrefix("command:") || trimmed.contains("`") ? "command" : "by hand"
        }
    }

    /// A step the goal can switch off for itself (`skip:`); `known` is false for a name the goal skips that the project has no step for.
    struct Step: Equatable {
        var name: String
        var label: String
        var skipped: Bool
        var known: Bool
        /// Why the step cannot run for this goal whatever the switch says (core's `Goal.unavailable`): the judge of a goal with no
        /// criteria. Nil when it can.
        var unavailable: String?
    }

    var title: String
    var path: String
    var request: String
    var rows: [Row]
    var outOfScope: [String]
    var model: String
    var budget: String
    var turnTimeout: String
    var allowedTools: [String]
    var grantedTools: [String]
    /// Other repositories the project's config lets a run read, as written there (read-only).
    var readAlso: [String] = []
    /// Folders this goal adds to those (`read_also:` in the goal), editable while the goal is a draft.
    var goalReadAlso: [String] = []
    /// Steps after a turn and whether this goal skips them.
    var steps: [Step] = []
    /// `quick: true`: the goal may have no criteria, and with none the request is all there is to check against.
    var quick = false
    /// The goal can be changed here: it is not approved (an approved goal is in another step), no run holds it and it has not ended.
    var editable = false
    var pill: Pill
    /// What stops the goal from being approved or run: the goal's own problems, a placeholder, a config that does not
    /// parse. Empty when nothing does.
    var blockers: [String]
    /// The template's placeholder lines are still there: the next step, not an error.
    var placeholdersRemain: Bool

    var checkable: Int { rows.filter { $0.warning == nil }.count }
    var checkableText: String { "\(checkable) of \(rows.count) checkable" }
    var canApprove: Bool { blockers.isEmpty && !placeholdersRemain && rows.allSatisfy { $0.warning == nil } }

    /// A goal that does not parse: the file's problems in words, and nothing else to show.
    static func invalid(path: String, problems: [String]) -> GoalModel {
        GoalModel(
            title: "", path: path, request: "", rows: [], outOfScope: [], model: "", budget: "", turnTimeout: "",
            allowedTools: [], grantedTools: [], pill: .draft, blockers: problems,
            placeholdersRemain: false)
    }

    /// Reads the goal file, the config and the log. `verifierSkill` is asked whether the project's verifier can run on the
    /// goal's base, and only when some criterion's proof is a screenshot: the answer costs a git read.
    static func load(
        project: Project, thread id: String,
        verifierSkill: @Sendable (Config, Goal) async -> Bool
    ) async -> GoalModel {
        let path = ".workbench/threads/\(id)/goal.md"
        guard let text = try? String(contentsOf: project.goalURL(id), encoding: .utf8) else {
            return .invalid(path: path, problems: ["The goal file \(path) is missing."])
        }
        let file: GoalFile
        do { file = try GoalFile.parse(text) } catch let error as GoalParseError {
            return .invalid(path: path, problems: error.problems.map(\.description))
        } catch {
            return .invalid(path: path, problems: ["\(error)"])
        }
        let goal = file.goal
        var blockers: [String] = []
        let placeholders = text.contains("TODO(workbench)")

        // No config means no tool set to judge proofs against; one that is there but broken is an error to show.
        var config: Config?
        if FileManager.default.fileExists(atPath: project.configURL.path) {
            do { config = try Config.load(from: project.configURL) } catch {
                blockers.append("The config (.workbench/config.toml) does not load: \(error)")
            }
        }

        var warnings: [ProofWarning] = []
        if let config {
            let usesScreenshot = goal.criteria.contains { ScreenshotProof.name(in: $0.proof) != nil }
            let skill = usesScreenshot ? await verifierSkill(config, goal) : true
            warnings = ProofCommands.warnings(goal: goal, config: config, verifierSkillAvailable: skill)
        }
        let rows = goal.criteria.map { criterion in
            let hit = warnings.first { $0.criterion == criterion.id }
            return Row(
                id: criterion.id, text: criterion.text, proof: criterion.proof,
                warning: hit.map(\.line), suggestion: hit?.suggestion)
        }

        let events = (try? EventLogReader.read(at: project.eventsURL(id)).events) ?? []
        let state = ThreadState.derive(from: events, id: id)
        let editable =
            goal.approval != .approved && state.decision == nil && ThreadStore(project: project).runnerPID(id: id) == nil
        let agent = config?.resolvedRunAgent(goalModel: goal.model)
        let pill: Pill =
            switch goal.approval {
            case .draft: .draft
            case .approved: .approved
            case .stale: .changedSinceApproval
            }
        return GoalModel(
            title: goal.title, path: path, request: goal.request, rows: rows, outOfScope: goal.outOfScope,
            model: goal.model ?? agent?.model ?? "default",
            budget: goal.budgetUSD.map { "$\($0) per turn" } ?? "no dollar cap: bounded by \(goal.turnTimeoutMin) min per turn",
            turnTimeout: "\(goal.turnTimeoutMin) min per turn",
            allowedTools: config?.effectiveAllowedTools ?? [],
            grantedTools: config.map { GrantLedger(events: events).patternsForNextTurn(tools: $0.tools) } ?? [],
            readAlso: config?.readAlso ?? [], goalReadAlso: goal.readAlso, steps: steps(goal: goal, config: config),
            quick: goal.quick, editable: editable, pill: pill, blockers: blockers, placeholdersRemain: placeholders)
    }

    /// The steps that follow a turn in this project, in the order the pipeline walks them, then any name the goal skips that is none of them.
    static func steps(goal: Goal, config: Config?) -> [Step] {
        // Only the built-in steps need criteria: a stage that shares a name with one reviews the diff and is never unavailable.
        var steps: [Step] = []
        if config?.verifier != nil {
            steps.append(
                Step(
                    name: "verifier", label: "Verifier", skipped: goal.skips("verifier"), known: true,
                    unavailable: goal.unavailable("verifier")))
        }
        steps.append(
            Step(
                name: "judge", label: "Judge", skipped: goal.skips("judge"), known: true,
                unavailable: goal.unavailable("judge")))
        for stage in config?.review.stages ?? [] where stage != ReviewConfig.prReviewStage {
            steps.append(Step(name: stage, label: stage, skipped: goal.skips(stage), known: true))
        }
        for name in goal.skip where !steps.contains(where: { $0.name == name }) {
            steps.append(Step(name: name, label: name, skipped: true, known: false))
        }
        return steps
    }

    /// Core's own check of the verifier's skill at the goal's base commit.
    static func coreVerifierSkill(project: Project) -> @Sendable (Config, Goal) async -> Bool {
        { config, goal in
            guard let git = try? GitRunner.discover() else { return false }
            return await VerifierSkill.isAvailable(config: config, git: git, repo: project.root, ref: goal.base)
        }
    }
}
