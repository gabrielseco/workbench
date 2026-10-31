import Foundation
import WorkbenchCore

/// What a ship would do, fetched before anything is pushed. `plan` and `description` go back to core exactly as read,
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

    /// Pushes and opens what `preview` read, as `workbench ship` does after its confirmation. Core builds the pull request text
    /// again at publish time, from the goal and the log, so it is compared with the preview's first: the describing turn takes
    /// a while, and text changed by an edit meanwhile is not published.
    static func publish(_ preview: ShipPreview, project: Project, thread: String) async throws -> ShipOutcome {
        let service = ThreadService(project: project, git: try GitRunner.discover())
        let gh = try? GitRunner.discover(tool: "gh")
        if let title = preview.title, let body = preview.body {
            let now = try await service.prBody(
                plan: preview.plan, description: preview.description, environment: gh?.environment ?? [:])
            try checkUnchanged(shown: (title, body), now: (now.title, now.body))
        }
        return try await service.publishShip(
            id: thread, gh: gh, plan: preview.plan, description: preview.description,
            screenshotTool: try? GitRunner.discover(tool: "pr-shots", timeout: 180))
    }

    struct TextChanged: Error, CustomStringConvertible {
        var description: String {
            "the pull request text changed since it was shown (the goal or the log was edited); nothing was pushed. "
                + "Press Ship again."
        }
    }

    /// Refuses a publish whose title or body is not the one that was shown.
    static func checkUnchanged(shown: (title: String, body: String), now: (title: String, body: String)) throws {
        guard shown == now else { throw TextChanged() }
    }
}
