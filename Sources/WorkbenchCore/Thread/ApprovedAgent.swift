import Foundation

/// The coding settings an approval was given for (`goal.approved` `provider` and `model`). A nil model is the
/// provider's own default.
public struct ApprovedAgent: Sendable, Equatable {
    public var provider: String
    public var model: String?

    public init(provider: String, model: String?) {
        self.provider = provider
        self.model = model
    }

    init?(_ event: Event) {
        guard let provider = event.data["provider"]?.stringValue else { return nil }
        self.init(provider: provider, model: event.data["model"]?.stringValue)
    }

    public init(_ agent: ResolvedAgent) { self.init(provider: "\(agent.provider)", model: agent.model) }

    public var description: String { "\(provider), \(model ?? "default model")" }
}
