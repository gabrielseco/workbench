import Foundation

/// Names the goal agent in a project's config, for a person who starts drafting before the config says who drafts.
/// Drafting spends money, so it is only ever on because the config names a provider: this writes that line, once, on request.
public enum GoalAgentSetup {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupported(String)
        case noConfig
        case alreadyThere
        case notWritten(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .unsupported(let id): "'\(id)' cannot draft goals: use claude or codex."
            case .noConfig: "this project has no .workbench/config.toml yet: run `workbench init` first."
            case .alreadyThere:
                "the config already has an [agents.goal] table that names no provider: add `provider = \"claude\"` or "
                    + "`provider = \"codex\"` to it by hand."
            case .notWritten(let why): "the config could not be written: \(why)"
            case .invalid(let why): "the config would not load with [agents.goal] added, so it was left as it was: \(why)"
            }
        }
    }

    /// Appends `[agents.goal]` with `provider` to the project's config, leaving every other line as it
    /// was. A config that does not load afterwards is put back exactly as it was.
    public static func enable(provider: AgentProviderID, in project: Project) throws {
        guard AgentRole.goal.supportedProviders.contains(provider) else { throw Failure.unsupported(provider.rawValue) }
        let url = project.configURL
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.noConfig }
        let before = existing
        let hasTable = before.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[agents.goal]")
        }
        if hasTable { throw Failure.alreadyThere }
        let gap = before.isEmpty ? "" : (before.hasSuffix("\n") ? "\n" : "\n\n")
        let text = before + gap + "[agents.goal]\nprovider = \"\(provider.rawValue)\"\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.notWritten("\(error)")
        }
        do {
            guard try Config.load(from: url).resolvedGoalAgent?.provider == provider else {
                throw Failure.invalid("[agents.goal] was not read")
            }
        } catch {
            try? existing.write(to: url, atomically: true, encoding: .utf8)
            throw error as? Failure ?? Failure.invalid("\(error)")
        }
    }
}
