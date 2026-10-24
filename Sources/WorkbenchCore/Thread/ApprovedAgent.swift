import Foundation

/// The coding settings an approval was given for (`goal.approved` `provider` and `model`). A nil model is the
/// provider's own default.
public struct ApprovedAgent: Sendable, Equatable {
    public var provider: String
    public var model: String?
    /// Nil is the provider's own setting; an approval from before the key existed recorded none.
    public var reasoningEffort: String?
    /// `hard_cap` or `timeout_only`, as the goal said when it was approved. An approval from before the key existed
    /// recorded none and was a hard cap.
    public var spendPolicy: String

    public init(provider: String, model: String?, reasoningEffort: String? = nil, spendPolicy: String = "hard_cap") {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.spendPolicy = spendPolicy
    }

    init?(_ event: Event) {
        guard let provider = event.data["provider"]?.stringValue else { return nil }
        self.init(
            provider: provider, model: event.data["model"]?.stringValue,
            reasoningEffort: event.data["reasoning_effort"]?.stringValue,
            spendPolicy: event.data["spend_policy"]?.stringValue ?? "hard_cap")
    }

    public init(_ agent: ResolvedAgent, spendPolicy: String = "hard_cap") {
        self.init(
            provider: "\(agent.provider)", model: agent.model, reasoningEffort: agent.reasoningEffort, spendPolicy: spendPolicy)
    }

    public var description: String {
        let effort = reasoningEffort.map { ", effort \($0)" } ?? ""
        return "\(provider), \(model ?? "default model")\(effort)" + (spendPolicy == "timeout_only" ? ", no dollar cap" : "")
    }
}
