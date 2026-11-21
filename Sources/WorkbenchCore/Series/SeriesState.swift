import Foundation

/// The thread a step started, as the driver recorded it in `.workbench/series/<name>/steps.jsonl` (one JSON object per line).
public struct SeriesRecord: Sendable, Equatable {
    public var step: Int
    public var thread: String
    public var at: String

    public init(step: Int, thread: String, at: String) { (self.step, self.thread, self.at) = (step, thread, at) }
}

public struct SeriesStepLog: Sendable {
    public let url: URL

    public init(project: Project, series: String) {
        url = project.seriesDirectory(series).appendingPathComponent("steps.jsonl")
    }

    /// The latest record of each step. A line that does not read is skipped, and so is a thread name that is not a thread id:
    /// nothing from the file reaches a path unchecked.
    public func read() -> [Int: SeriesRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var found: [Int: SeriesRecord] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let step = object["step"] as? Int, let thread = object["thread"] as? String, SafeNames.isThreadID(thread)
            else { continue }
            found[step] = SeriesRecord(step: step, thread: thread, at: object["at"] as? String ?? "")
        }
        return found
    }

    public func append(_ record: SeriesRecord) throws {
        let object: [String: Any] = ["step": record.step, "thread": record.thread, "at": record.at]
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

/// Where one step is, derived from its thread's log and its pull request's checks. Nothing here is stored.
public enum SeriesStepState: Sendable, Equatable {
    /// No thread yet.
    case pending
    /// The thread is working, or has not opened its pull request.
    case running(thread: String)
    /// The pull request is open and something it needs has not happened yet (checks running, a review not clean).
    case waiting(thread: String, reason: String)
    /// The pull request is open (or merged), its checks passed and the last review of its head was clean.
    case clean(thread: String, pullRequest: String?)
    /// Cannot go on without a person.
    case stopped(thread: String, reason: String)

    public var isClean: Bool {
        if case .clean = self { return true }
        return false
    }
}

/// What is known about a step's thread when its state is asked for.
public struct SeriesStepFacts: Sendable {
    public var thread: String
    public var state: ThreadState
    /// The pull request's checks; nil when they could not be read (`checksError` says why) or there is no pull request.
    public var checks: PRChecksSummary?
    public var checksError: String?
    /// What GitHub says now: the pull request's state and its current head. The log records only what happened through
    /// Workbench, so a merge or a close on GitHub, or a commit pushed after the review, is seen only here.
    public var live: (state: PRState, head: String)?
    public var liveError: String?

    public init(
        thread: String, state: ThreadState, checks: PRChecksSummary? = nil, checksError: String? = nil,
        live: (state: PRState, head: String)? = nil, liveError: String? = nil
    ) {
        (self.thread, self.state, self.checks, self.checksError) = (thread, state, checks, checksError)
        (self.live, self.liveError) = (live, liveError)
    }
}

public enum SeriesScheduler {
    /// A step is clean when its pull request is open with every check `pass` or `skipping` (never "the command exited 0": a
    /// cancelled check exits 0) and the last review round of its head commit had the verdict `clean`. A merged one is clean.
    public static func state(_ facts: SeriesStepFacts?) -> SeriesStepState {
        guard let facts else { return .pending }
        let (thread, state) = (facts.thread, facts.state)
        func stopped(_ reason: String) -> SeriesStepState { .stopped(thread: thread, reason: reason) }
        guard let pr = state.pullRequest else {
            if let decision = state.decision, decision != "accepted" {
                return stopped("the thread was \(decision) without a pull request")
            }
            if state.decision == "accepted" { return stopped("the thread was accepted but not shipped: workbench ship") }
            return .running(thread: thread)
        }
        if state.isMerged { return .clean(thread: thread, pullRequest: pr.url) }
        if state.isClosed { return stopped("the pull request was closed without merging") }
        func waiting(_ reason: String) -> SeriesStepState { .waiting(thread: thread, reason: reason) }

        // A person's merge or close on GitHub counts even when no Workbench command recorded it; a merge is the decision that
        // matters, so it needs no checks or review of its own.
        if let error = facts.liveError { return waiting("the pull request could not be read: \(error)") }
        guard let live = facts.live else { return waiting("the pull request has not been read") }
        switch live.state {
        case .merged: return .clean(thread: thread, pullRequest: pr.url)
        case .closed: return stopped("the pull request was closed without merging")
        case .open: break
        }
        if let error = facts.checksError { return waiting("the checks could not be read: \(error)") }
        guard let checks = facts.checks else { return waiting("the checks have not been read") }
        switch checks.state {
        case .none: return waiting("no checks reported yet")
        case .pending: return waiting("the checks are still running")
        case .failed:
            let names = checks.checks.filter { $0.outcome == .failed }.map(\.name).sorted().joined(separator: ", ")
            return stopped("checks failed: \(names)")
        case .passed: break
        }
        guard let review = state.review.prReview else { return waiting("no review of the pull request yet") }
        if review.isOpen { return waiting("a review round is running") }
        guard let verdict = review.verdict else {
            return stopped("the review round \(review.round) had no verdict: \(review.failure ?? "no reason recorded")")
        }
        // The head GitHub has now, not the one the pull request was opened at: a commit pushed after the review is unreviewed.
        if review.headSHA != live.head { return waiting("the last review was of an older commit") }
        return verdict == "clean" ? .clean(thread: thread, pullRequest: pr.url) : waiting("the review asked for fixes")
    }

    /// The steps a driver may start now: pending, every `after` step clean, and nothing stopped anywhere in the series.
    public static func ready(_ definition: SeriesDefinition, states: [Int: SeriesStepState]) -> [Int] {
        guard stoppedStep(definition, states: states) == nil else { return [] }
        return definition.steps.filter { step in
            (states[step.number] ?? .pending) == .pending && step.after.allSatisfy { states[$0]?.isClean == true }
        }.map(\.number)
    }

    public static func stoppedStep(
        _ definition: SeriesDefinition, states: [Int: SeriesStepState]
    ) -> (step: Int, reason: String)? {
        for step in definition.steps {
            if case .stopped(_, let reason)? = states[step.number] { return (step.number, reason) }
        }
        return nil
    }

    /// What each step waits for before it can start, for `status`: the earlier steps not yet clean.
    public static func blockedBy(_ step: SeriesStep, states: [Int: SeriesStepState]) -> [Int] {
        step.after.filter { states[$0]?.isClean != true }
    }
}

extension SeriesLibrary {
    /// Reads every recorded step's thread (in the step's own project) and asks `gh` about the checks of the ones with an open
    /// pull request. Read only. A step with no record is pending.
    public func states(
        _ loaded: LoadedSeries, git: GitRunner, gh: GitRunner?
    ) async -> [Int: SeriesStepState] {
        let records = SeriesStepLog(project: project, series: loaded.definition.name).read()
        var result: [Int: SeriesStepState] = [:]
        for step in loaded.definition.steps {
            guard let record = records[step.number], let root = loaded.projects[step.number] else {
                result[step.number] = .pending
                continue
            }
            let other = Project(root: root)
            let state = ThreadStore(project: other).state(of: record.thread)
            var facts = SeriesStepFacts(thread: record.thread, state: state)
            if let number = state.pullRequest?.number, !state.isMerged, !state.isClosed {
                let service = ThreadService(project: other, git: git)
                switch await service.prState(number: number, gh: gh) {
                case .success(let live): facts.live = live
                case .failure(let error): facts.liveError = error.why
                }
                if facts.live?.state == .open {
                    do { facts.checks = try await service.prChecks(id: record.thread, gh: gh) } catch {
                        facts.checksError = "\(error)"
                    }
                }
            }
            result[step.number] = SeriesScheduler.state(facts)
        }
        return result
    }
}
