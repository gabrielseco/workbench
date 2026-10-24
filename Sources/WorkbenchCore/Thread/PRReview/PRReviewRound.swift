import Foundation

// MARK: Value types

struct PRReviewSettings: Sendable {
    var codexPath: String
    var environment: [String: String]
    var timeout: TimeInterval
    var capacityBackoff: @Sendable (Int) -> TimeInterval
    var stopRequested: @Sendable () -> Bool
}

struct PRReviewPaths: Sendable {
    var folder: URL
    var tree: URL
    var brief: URL
    var diff: URL
    var answer: URL
    var transcript: URL

    /// `tag` keeps the files of rounds counted apart (before and after the pull request) from sharing a name.
    init(folder: URL, round: Int, tag: String = "") {
        self.folder = folder
        tree = folder.appendingPathComponent("round-\(round)\(tag).tree")
        brief = folder.appendingPathComponent("round-\(round)\(tag).brief.md")
        diff = folder.appendingPathComponent("round-\(round)\(tag).diff.patch")
        answer = folder.appendingPathComponent("round-\(round)\(tag).findings.md")
        transcript = folder.appendingPathComponent("round-\(round)\(tag).transcript.txt")
    }
}

struct PRReviewRound: Sendable {
    var id: String
    var stage: ReviewStage
    var pr: Int
    var branch: String
    var base: String
    var recordedBase: String?
    var goal: String
    /// Where the rest of `goal` is, said in the brief when the goal is cut: its file, or the pull request.
    var goalRest: String
    var tip: String
    var paths: PRReviewPaths
    var config: Config
    var settings: PRReviewSettings
    /// The commit that was reviewed: the branch tip on origin when the round began.
    var reviewedSHA: String?
    /// The base branch's commit the diff and the instructions come from.
    var baseSHA: String?
    /// The verify step's screenshots for a stage that reads `proof`, or why there are none; nil for other stages.
    var proof: Result<[String], PRReviewFailure>?
    var warnings: [String] = []
    /// The session a Claude reviewer is started with, chosen once so the argv on record is the argv that runs.
    var sessionID = UUID().uuidString.lowercased()
    /// Where this round's provider processes are put on record; nil when the round runs outside a thread's log.
    var attempts: AttemptLog?

    /// Provider and model this stage resolves to.
    var agent: ResolvedAgent { config.resolvedReviewAgent(stage: stage.name) }
    var executable: String { agent.provider == .codex ? settings.codexPath : config.executable(for: agent.provider) }

    func makeProvider() -> (any AgentProvider)? {
        agent.provider == .codex ? CodexProvider(executable: settings.codexPath) : config.agentProvider(agent.provider)
    }

    func spend(capabilities: AgentCapabilities) -> Result<AgentSpend, AgentFailure> {
        AgentSpendPolicy.spend(
            role: .review, agent: agent, capabilities: capabilities, cap: PRReview.claudeBudgetUSD,
            legacy: config.reviewUsesLegacySelection(stage: stage.name),
            table: config.allowUnpricedTable(.review, stage: stage.name))
    }
}

struct PRReviewFailure: Error, Sendable {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

struct PRReviewOutcome: Sendable {
    var verdict: PRReviewVerdict?
    var failure: String?
    var findings: String?
    var warnings: [String] = []
    /// What the provider reported; nil when it reports none (Codex), never 0.
    var costUSD: Double?

    mutating func failed(_ reason: String, answer: String? = nil) -> PRReviewOutcome {
        failure = reason
        findings = answer
        return self
    }

    mutating func failed(_ reason: PRReviewFailure) -> PRReviewOutcome { failed(reason.reason) }
}

extension String {
    /// The first non-empty line, for a one-line reason.
    var firstLine: String {
        split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}
