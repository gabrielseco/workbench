import Foundation

/// The models each provider's menu offers in the app's Agents card. This is the one place to update when a provider's models change: edit
/// the table, merge, and the post-merge hook rebuilds the app. Nothing here is checked against the provider (a model the menu lacks is
/// chosen with `Other…`), and nothing reads it but the menu.
///
/// Claude's are its aliases, which follow the provider's latest model of that kind, so they do not go stale. Codex's are the models its CLI
/// lists as visible (`codex debug models`), in its own order: `scripts/update-model-catalog.sh` rewrites that line from the installed CLI.
public enum ModelCatalog {
    public static let models: [AgentProviderID: [String]] = [
        .claude: ["opus", "sonnet", "haiku"],
        // swiftlint:disable:next line_length
        .codex: ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"],
    ]

    public static func names(for provider: AgentProviderID) -> [String] { models[provider] ?? [] }
}
