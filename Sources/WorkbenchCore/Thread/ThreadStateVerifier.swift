import Foundation

extension Review {
    /// The latest verifier run (P10): what `verifier.started` / `verifier.ended` / `verifier.skipped` and the
    /// `proof.added` lines it wrote said. Advisory: its words are a note, never a pass.
    public struct Verifier: Sendable, Equatable {
        public var turn: Int
        /// True only for a run that ended on its own with an answer.
        public var ok: Bool
        /// Why it did not finish well, or (for a skip) why it did not start; nil when `ok`.
        public var reason: String?
        public var skipped: Bool
        public var costUSD: Double?
        public var durationMs: Int?
        /// What it said last, bounded; empty when it said nothing.
        public var report: String
        /// The PNGs it recorded as proof.
        public var proof: [ProofFile]
        /// The run began and no end was recorded (still running, or cut off).
        public var open: Bool
    }

    /// The proof of one turn: what the verifier left, as the log recorded it. A skipped run has none.
    public struct ProofSet: Sendable, Equatable {
        public var turn: Int
        public var files: [ProofFile]
        public var verifier: Verifier

        /// Where the proof came from, for a line of the report.
        public var source: String { verifier.ok ? "verifier finished" : "verifier did not finish" }

        public init?(verifier: Verifier?) {
            guard let verifier, !verifier.skipped else { return nil }
            turn = verifier.turn
            files = verifier.proof
            self.verifier = verifier
        }
    }
}

extension ThreadState {
    static func proofFile(_ event: Event) -> ProofFile? {
        guard let name = event.data["name"]?.stringValue, let path = event.data["path"]?.stringValue else { return nil }
        return ProofFile(
            name: name, path: path, sha256: event.data["sha256"]?.stringValue ?? "", bytes: event.data["bytes"]?.intValue ?? 0,
            commit: event.data["commit"]?.stringValue, tree: event.data["tree"]?.stringValue)
    }

    /// Each name once, the last recorded winning, in the order the names first appeared.
    static func latestByName(_ files: [ProofFile]) -> [ProofFile] {
        var order: [String] = []
        var latest: [String: ProofFile] = [:]
        for file in files {
            if latest[file.name] == nil { order.append(file.name) }
            latest[file.name] = file
        }
        return order.compactMap { latest[$0] }
    }

    /// The verifier's events: its `proof.added` lines gather until `verifier.ended` closes the run.
    static func applyVerifier(_ event: Event, to state: inout ThreadState, pending: inout [ProofFile]) {
        switch event.kind {
        case .verifierStarted:
            // A run again for the same turn keeps what an earlier run left: a file it did not change is not
            // recorded again, and it is still the turn's proof (the files are checked against the disk when read).
            pending = state.review.verifier.flatMap { $0.turn == event.turn ? $0.proof : nil } ?? []
            state.review.verifier = Review.Verifier(
                turn: event.turn, ok: false, reason: "started and never recorded an end (still running, or it was interrupted)",
                skipped: false, costUSD: nil, durationMs: nil, report: "", proof: [], open: true)
        case .verifierSkipped:
            state.review.verifier = Review.Verifier(
                turn: event.turn, ok: false, reason: event.data["reason"]?.stringValue, skipped: true, costUSD: nil,
                durationMs: nil, report: "", proof: [], open: false)
        default:
            state.review.verifier = Review.Verifier(
                turn: event.turn, ok: event.data["ok"] == true, reason: event.data["reason"]?.stringValue, skipped: false,
                costUSD: { if case .double(let d)? = event.data["cost_usd"] { d } else { nil } }(),
                durationMs: event.data["duration_ms"]?.intValue, report: event.data["report"]?.stringValue ?? "",
                proof: Self.latestByName(pending), open: false)
            pending = []
        }
    }
}
