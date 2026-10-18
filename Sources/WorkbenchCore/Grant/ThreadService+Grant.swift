import Foundation

/// Why `grant` did not record anything.
public enum GrantError: Error, Equatable, CustomStringConvertible {
    case refused(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .refused(let message), .notFound(let message): message
        }
    }
}

public struct GrantOutcome: Sendable, Equatable {
    public var pattern: String
    public var scope: GrantScope
    public var level: DeniedCommandAssessment.Level
    /// The `grant.added` event, nil when the same decision was already on record.
    public var seq: Int?
}

extension ThreadService {
    /// The denied commands of a thread with their numbers, ratings and what was decided about them.
    public func grantCandidates(id: String) throws -> [GrantCandidate] {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        return GrantCandidates.derive(events: try EventLogReader.read(at: project.eventsURL(id)).events)
    }

    /// Records what to do about one denied command (`2`) or one part of a compound (`2.1`).
    ///
    /// Nothing is recorded for a decided thread, a live run, a compound as a whole, text that cannot be written as
    /// a fixed pattern, a pattern the project denies, or `unsafe` without `allowDangerous` (and then only `once`).
    /// The next turn picks the decision up from the log (`GrantLedger`); nothing is written to the config.
    public func grant(
        id: String, target: String, scope: GrantScope, allowDangerous: Bool = false, by: String = "user"
    ) async throws -> GrantOutcome {
        guard SafeNames.isThreadID(id) else { throw ThreadStoreError.invalidName(id) }
        if let pid = runnerPID(id: id) { throw ThreadServiceError.running(pid: pid) }
        let config = try Config.load(from: project.configURL)
        // Everything is checked again under the log's lock, so a decision recorded or a thread ended by another
        // command between the check and the write is seen.
        return try await withLog(id) { log in
            if let decision = ThreadStore(project: project).state(of: id).decision {
                throw ThreadServiceError.threadEnded(decision)
            }
            let events = try EventLogReader.read(at: project.eventsURL(id)).events
            let choice = try Self.choose(target, scope, GrantCandidates.derive(events: events), config, allowDangerous)

            let ledger = GrantLedger(events: events)
            // The same decision, or a thread grant when `once` is asked, is already on record.
            let counting = ledger.records.last { record in
                record.pattern == choice.pattern && (record.scope != .once || record.seq > ledger.lastTurnStartSeq)
            }
            if let counting, counting.scope == scope || (counting.scope == .thread && scope == .once) {
                return GrantOutcome(pattern: choice.pattern, scope: counting.scope, level: choice.level, seq: nil)
            }
            var data: [String: JSONValue] = [
                "scope": .string(scope.rawValue), "pattern": .string(choice.pattern),
                "level": .string("\(choice.level)"), "by": .string(by),
            ]
            if let seq = choice.denialSeq { data["denial_seq"] = .int(seq) }
            let event = try await log.append(.grantAdded, data: .object(data))
            return GrantOutcome(pattern: choice.pattern, scope: scope, level: choice.level, seq: event.seq)
        }
    }

    private struct Choice {
        var pattern: String
        var level: DeniedCommandAssessment.Level
        var denialSeq: Int?
    }

    /// What the target names and the pattern that would be recorded for it, or why not.
    private static func choose(
        _ target: String, _ scope: GrantScope, _ candidates: [GrantCandidate], _ config: Config, _ allowDangerous: Bool
    ) throws -> Choice {
        let (candidate, part) = try resolve(target, in: candidates)
        if let part {
            let pattern = try patternToRecord(
                part: part, candidate: candidate, scope: scope, config: config, allowDangerous: allowDangerous)
            return Choice(pattern: pattern, level: part.level, denialSeq: candidate.seqs.last)
        }
        // A whole compound: only a refusal can be recorded for it.
        guard scope == .never else {
            let parts = candidate.parts.map(\.number).joined(separator: ", ")
            throw GrantError.refused(
                "\(candidate.number) is several commands in one and is not granted whole. Grant a part: \(parts)")
        }
        return Choice(pattern: candidate.wholePattern, level: candidate.assessment.level, denialSeq: candidate.seqs.last)
    }

    /// `3` or `3.2`: the candidate and, for a plain command or a named part, the part. A compound named by its
    /// number alone has no part.
    static func resolve(_ target: String, in candidates: [GrantCandidate]) throws -> (GrantCandidate, GrantCandidate.Part?) {
        let pieces = target.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), let number = Int(pieces[0]), number > 0,
            pieces.count == 1 || Int(pieces[1]).map({ $0 > 0 }) == true
        else { throw GrantError.refused("'\(target)' is not a denial number like 3 or 3.2") }
        guard let candidate = candidates.first(where: { $0.number == number }) else {
            throw GrantError.notFound("no denied command \(number) (this thread has \(candidates.count))")
        }
        if pieces.count == 2 {
            guard candidate.assessment.isCompound, let part = Int(pieces[1]), part <= candidate.parts.count else {
                throw GrantError.notFound("\(number) has no part \(pieces[1])")
            }
            return (candidate, candidate.parts[part - 1])
        }
        return (candidate, candidate.assessment.isCompound ? nil : candidate.parts.first)
    }

    private static func patternToRecord(
        part: GrantCandidate.Part, candidate: GrantCandidate, scope: GrantScope, config: Config, allowDangerous: Bool
    ) throws -> String {
        if scope == .never {
            return part.pattern ?? GrantCandidate.neverPattern(tool: candidate.tool, text: part.command)
        }
        guard let pattern = part.pattern else {
            let why = part.reasons.first.map { ": \($0)" } ?? ""
            throw GrantError.refused("\(part.number) cannot be granted as written\(why)")
        }
        if let problem = GrantPattern.problem(pattern, available: config.tools.available) {
            throw GrantError.refused("\(pattern) cannot be granted: \(problem)")
        }
        if let entry = GrantPattern.deniedBy(pattern, denied: config.tools.denied) {
            throw GrantError.refused("\(pattern) is blocked by [tools] denied (\(entry)), which a grant does not override")
        }
        if part.level == .unsafe {
            guard allowDangerous else {
                let why = part.reasons.first.map { " (\($0))" } ?? ""
                throw GrantError.refused("\(part.number) is unsafe\(why). It needs --allow-dangerous, and only --once")
            }
            guard scope == .once else { throw GrantError.refused("\(part.number) is unsafe, so it can only be granted --once") }
        }
        return pattern
    }
}
