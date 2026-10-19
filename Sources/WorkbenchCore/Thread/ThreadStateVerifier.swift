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

    /// The proof of one turn: what the verify step and the verifier left, as the log recorded it. The verifier's
    /// file wins a name both left (both stay in the log); a step of an earlier turn is not part of it.
    public struct ProofSet: Sendable, Equatable {
        public var turn: Int
        public var files: [ProofFile]
        public var verify: Verify?
        public var verifier: Verifier?

        /// Where the proof came from, for a line of the report: `verify passed`, `verifier finished`, or both.
        public var source: String {
            var parts: [String] = []
            if let verify { parts.append("verify \(verify.result.replacingOccurrences(of: "_", with: " "))") }
            if let verifier, !verifier.skipped {
                parts.append(verifier.ok ? "verifier finished" : "verifier did not finish")
            }
            return parts.joined(separator: ", ")
        }

        public init?(verify: Verify?, verifier: Verifier?) {
            let ranVerifier = verifier.flatMap { $0.skipped ? nil : $0 }
            guard let turn = [verify?.turn, ranVerifier?.turn].compactMap({ $0 }).max() else { return nil }
            self.turn = turn
            self.verify = verify?.turn == turn ? verify : nil
            self.verifier = ranVerifier?.turn == turn ? ranVerifier : nil
            let own = self.verifier?.proof ?? []
            let names = Set(own.map(\.name))
            files = own + (self.verify?.proof ?? []).filter { !names.contains($0.name) }
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
