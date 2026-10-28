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
    var pill: Pill
    /// What stops the goal from being approved or run: the goal's own problems, a placeholder, a config that does not
    /// parse. Empty when nothing does.
    var blockers: [String]

    var checkable: Int { rows.filter { $0.warning == nil }.count }
    var checkableText: String { "\(checkable) of \(rows.count) checkable" }
    var canApprove: Bool { blockers.isEmpty && rows.allSatisfy { $0.warning == nil } }

    /// A goal that does not parse: the file's problems in words, and nothing else to show.
    static func invalid(path: String, problems: [String]) -> GoalModel {
        GoalModel(
            title: "", path: path, request: "", rows: [], outOfScope: [], model: "", budget: "", turnTimeout: "",
            allowedTools: [], grantedTools: [], pill: .draft, blockers: problems)
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
        if text.contains("TODO(workbench)") { blockers.append("Placeholders remain: replace every TODO(workbench).") }

        // No config means no tool set to judge proofs against; one that is there but broken is an error to show.
        var config: Config?
        if FileManager.default.fileExists(atPath: project.configURL.path) {
            do { config = try Config.load(from: project.configURL) } catch {
                blockers.append("The config does not load: \(error)")
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
            pill: pill, blockers: blockers)
    }

    /// Core's own check of the verifier's skill at the goal's base commit.
    static func coreVerifierSkill(project: Project) -> @Sendable (Config, Goal) async -> Bool {
        { config, goal in
            guard let git = try? GitRunner.discover() else { return false }
            return await VerifierSkill.isAvailable(config: config, git: git, repo: project.root, ref: goal.base)
        }
    }
}
