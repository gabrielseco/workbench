import Foundation
import WorkbenchCore

/// What a ship would do, fetched and shown before anything is pushed. `plan` and `description` go back to core exactly as shown,
/// and core refuses them when the branch or the target moved since.
struct ShipPreview: Equatable, Sendable {
    var plan: ShipPlan
    /// The model's description for a new pull request; nil for the goal-based text, or when the pull request already exists.
    var description: PRDescription?
    /// What the pull request will say; nil when the thread continues an open one, whose title and text stay as they are.
    var title: String?
    var body: String?
    /// Why the goal-based text is used when the describing turn did not give one.
    var note: String?

    var updatesExistingPullRequest: Bool { plan.updatesExistingBranch }

    /// Preflight, then the describing turn, then the body it would open the pull request with. Nothing is pushed or recorded as shipped.
    static func fetch(project: Project, thread: String) async throws -> ShipPreview {
        let service = ThreadService(project: project, git: try GitRunner.discover())
        let gh = try? GitRunner.discover(tool: "gh")
        let plan = try await service.shipPreflight(id: thread, gh: gh)
        if plan.updatesExistingBranch { return ShipPreview(plan: plan) }
        var description: PRDescription?
        var note: String?
        if let config = try? Config.load(from: project.configURL) {
            let described = try await service.describePR(plan: plan, config: config)
            description = described.description
            note = described.fallback.map { "Could not describe the change (\($0)); using the goal-based description." }
        } else {
            note = "No readable .workbench/config.toml; using the goal-based description."
        }
        let body = try await service.prBody(plan: plan, description: description, environment: gh?.environment ?? [:])
        return ShipPreview(plan: plan, description: description, title: body.title, body: body.body, note: note)
    }

    /// Pushes and opens what `preview` showed, as `workbench ship` does after its confirmation.
    static func publish(_ preview: ShipPreview, project: Project, thread: String) async throws -> ShipOutcome {
        let service = ThreadService(project: project, git: try GitRunner.discover())
        return try await service.publishShip(
            id: thread, gh: try? GitRunner.discover(tool: "gh"), plan: preview.plan, description: preview.description,
            screenshotTool: try? GitRunner.discover(tool: "pr-shots", timeout: 180))
    }

    /// The lines that say what will be pushed, in the words `workbench ship` prints them.
    var pushLines: [String] {
        var lines = ["thread:  \(plan.id)", "branch:  \(plan.branch)  (\(plan.head.prefix(12)))"]
        lines.append(plan.updatesExistingBranch ? "updates: \(plan.remoteBranch) on origin" : "base:    \(plan.base)")
        lines.append("origin:  \(plan.origin)")
        switch plan.remote {
        case .absent: lines.append("push:    new branch on origin")
        case .upToDate: lines.append("push:    nothing, origin already has this commit")
        case .behind(let sha): lines.append("push:    fast-forward from \(sha.prefix(12))")
        }
        return lines
    }
}
