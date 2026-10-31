import Foundation
import WorkbenchCore

/// What the window knows of the shipped pull request and its CI: being read for the first time, what GitHub said, or why it
/// could not say. Read from GitHub on the store's schedule and never stored in the log.
enum PullRequestCI: Equatable {
    case checking
    case known(PRStatus)
    case unavailable(String)

    /// One check as a row shows it.
    struct Row: Equatable, Hashable {
        enum Kind: Equatable, Hashable { case passed, skipped, running, failed }
        var name: String
        var kind: Kind

        var word: String {
            switch kind {
            case .passed: "passed"
            case .skipped: "skipped"
            case .running: "running"
            case .failed: "failed"
            }
        }
    }

    var status: PRStatus? { if case .known(let status) = self { status } else { nil } }

    /// Merge is offered only on what GitHub said just now: open, and every check passed.
    var canMerge: Bool { status?.canMerge ?? false }

    /// The pull request was merged or closed: nothing more to watch.
    var ended: Bool { status.map { $0.state != .open } ?? false }

    /// Why CI cannot be told, when it cannot: the read failed, or the checks could not be read.
    var unavailableReason: String? {
        switch self {
        case .checking: nil
        case .unavailable(let why): why
        case .known(let status): status.state == .open ? status.checksError : nil
        }
    }

    /// Still moving: read again soon.
    var isPending: Bool {
        switch self {
        case .checking: true
        case .unavailable: false
        case .known(let status): status.state == .open && status.checksError == nil && status.checks?.state == .pending
        }
    }

    var mergeBlocker: String? {
        switch self {
        case .checking: "Checking CI…"
        case .unavailable: "CI status is unavailable, so it is not known to be green."
        case .known(let status): status.mergeBlocker
        }
    }

    var rows: [Row] {
        guard let checks = status?.checks, status?.checksError == nil else { return [] }
        return checks.checks.map { check in
            let kind: Row.Kind =
                switch check.bucket {
                case "pass": .passed
                case "skipping": .skipped
                case "fail", "cancel": .failed
                default: .running
                }
            return Row(name: check.name, kind: kind)
        }
    }

    /// The one line over the rows: where CI stands, with counts.
    var summary: String {
        switch self {
        case .checking: return "CI: checking…"
        case .unavailable(let why): return "CI status unavailable: \(why)"
        case .known(let status):
            switch status.state {
            case .merged: return "Merged."
            case .closed: return "Closed without merging."
            case .open: break
            }
            if let why = status.checksError { return "CI status unavailable: \(why)" }
            guard let checks = status.checks, !checks.checks.isEmpty else { return "CI: no checks reported" }
            let rows = self.rows
            let order: [Row.Kind] = [.running, .failed, .passed, .skipped]
            let parts = order.compactMap { kind -> String? in
                let matching = rows.filter { $0.kind == kind }
                return matching.first.map { "\(matching.count) \($0.word)" }
            }
            let verdict =
                switch checks.state {
                case .pending: "running"
                case .failed: "failed"
                case .passed: "green"
                case .none: "no checks"
                }
            return "CI \(verdict): " + parts.joined(separator: " · ")
        }
    }
}
