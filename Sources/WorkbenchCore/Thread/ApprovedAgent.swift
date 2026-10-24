import Foundation

/// The coding settings an approval was given for (`goal.approved` `provider` and `model`). A nil model is the
/// provider's own default.
public struct ApprovedAgent: Sendable, Equatable {
    public var provider: String
    public var model: String?
    /// `hard_cap` or `timeout_only`, as the goal said when it was approved. An approval from before the key existed
    /// recorded none and was a hard cap.
    public var spendPolicy: String

    public init(provider: String, model: String?, spendPolicy: String = "hard_cap") {
        self.provider = provider
        self.model = model
        self.spendPolicy = spendPolicy
    }

    init?(_ event: Event) {
        guard let provider = event.data["provider"]?.stringValue else { return nil }
        self.init(
            provider: provider, model: event.data["model"]?.stringValue,
            spendPolicy: event.data["spend_policy"]?.stringValue ?? "hard_cap")
    }

    public init(_ agent: ResolvedAgent, spendPolicy: String = "hard_cap") {
        self.init(provider: "\(agent.provider)", model: agent.model, spendPolicy: spendPolicy)
    }

    public var description: String {
        "\(provider), \(model ?? "default model")" + (spendPolicy == "timeout_only" ? ", no dollar cap" : "")
    }
}
