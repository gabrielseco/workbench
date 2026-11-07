import Foundation

/// Names the goal agent in a project's config, for a person who starts drafting before the config says who drafts.
/// Drafting spends money, so it is only ever on because the config names a provider: this writes that line, once, on request.
public enum GoalAgentSetup {
    /// A config bigger than this is not read into memory to be edited.
    static let limit = 256 * 1024

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupported(String)
        case noConfig
        case alreadyThere
        case notWritten(String)
        case invalid(String)
        case tooLarge

        public var description: String {
            switch self {
            case .unsupported(let id): "'\(id)' cannot draft goals: use claude or codex."
            case .noConfig: "this project has no .workbench/config.toml yet: run `workbench init` first."
            case .alreadyThere:
                "the config already has an [agents.goal] table that names no provider: add `provider = \"claude\"` or "
                    + "`provider = \"codex\"` to it by hand."
            case .notWritten(let why): "the config could not be written: \(why)"
            case .tooLarge: "the config is over \(limit / 1024) KiB: add [agents.goal] by hand."
            case .invalid(let why): "the config would not load with [agents.goal] added, so it was left as it was: \(why)"
            }
        }
    }

    /// Appends `[agents.goal]` with `provider` to the project's config, leaving every other line as it was (`ConfigEdit` writes it).
    /// A config that does not load afterwards is left exactly as it was.
    public static func enable(provider: AgentProviderID, in project: Project) throws {
        guard AgentRole.goal.supportedProviders.contains(provider) else { throw Failure.unsupported(provider.rawValue) }
        let url = project.configURL
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            throw Failure.noConfig
        }
        guard size <= limit else { throw Failure.tooLarge }
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.noConfig }
        let hasTable = existing.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[agents.goal]")
        }
        if hasTable { throw Failure.alreadyThere }
        do {
            _ = try ConfigEdit.set(ConfigEdit.Key(role: .goal, field: .provider), to: provider.rawValue, in: project)
        } catch let failure as ConfigEdit.Failure {
            switch failure {
            case .noConfig: throw Failure.noConfig
            case .tooLarge: throw Failure.tooLarge
            case .notWritten(let why): throw Failure.notWritten(why)
            case .doesNotLoad(let why), .invalid(let why), .unsafe(let why): throw Failure.invalid(why)
            default: throw Failure.invalid("\(failure)")
            }
        }
    }
}
