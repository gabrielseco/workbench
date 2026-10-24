import Foundation

/// The line `pr-review`, `review-stage` and `ship --review-loop` print before a review starts, naming the agent the
/// config chose for it.
public enum ReviewProgress {
    private static let wait = "(read-only; this can take several minutes)..."

    /// `pr-review --pr <n>`.
    public static func pullRequest(_ number: Int, config: Config) -> String {
        "asking \(agentName(config)) to review pull request #\(number) \(wait)"
    }

    /// `pr-review [id]` and `review-stage <name> [id]`.
    public static func stage(_ name: String, thread id: String, config: Config) -> String {
        let agent = agentName(config, stage: name)
        return name == ReviewConfig.prReviewStage
            ? "asking \(agent) to review the pull request of \(id) \(wait)"
            : "asking \(agent) to review the pull request of \(id) as the \(name) stage \(wait)"
    }

    /// One round of `ship --review-loop`.
    public static func loopRound(config: Config) -> String {
        "asking \(agentName(config)) to review the pull request \(wait)"
    }

    static func agentName(_ config: Config, stage: String = ReviewConfig.prReviewStage) -> String {
        config.resolvedReviewAgent(stage: stage).provider == .claude ? "Claude" : "Codex"
    }
}
