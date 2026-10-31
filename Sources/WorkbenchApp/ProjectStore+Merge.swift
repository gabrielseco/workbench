import Foundation
import WorkbenchCore

/// The shipped pull request's CI as the store last read it, for the scope it names, and how often it is read again.
struct PullRequestCIState {
    var ci: PullRequestCI?
    var scope: String?
    var readAt: ContinuousClock.Instant?
    var reading = false
    /// While checks run, and once they settled or could not be read.
    var intervals: (pending: Duration, settled: Duration)
}

/// The shipped pull request's CI, read from GitHub while it is open, and Merge once it is green. Merging is only ever the person's
/// click: nothing here merges because CI turned green.
extension ProjectStore {
    /// The pull request on screen, as the scope its CI is kept for; nil when nothing shipped is shown. The generation is in it, so
    /// what was read before another project was opened is never shown again.
    private var pullRequestScope: String? {
        guard case .thread(let shown) = screen, let pr = shown.state.pullRequest, !shown.state.cleaned,
            let scope = currentScope
        else { return nil }
        return "\(generation)|\(scope)#\(pr.number)"
    }

    /// Whether the poll should read CI now: never read for this pull request, or read long enough ago. Not once it has ended.
    var pullRequestCIIsDue: Bool {
        guard let scope = pullRequestScope, !prCI.reading, !deciding else { return false }
        guard prCI.scope == scope, let ci = prCI.ci, let readAt = prCI.readAt else { return true }
        if ci.ended { return false }
        return readAt.duration(to: .now) >= (ci.isPending ? prCI.intervals.pending : prCI.intervals.settled)
    }

    /// Reads the pull request's state and CI once. A failed read is shown as unavailable, never as the last good answer.
    func refreshPullRequestCI() async {
        guard let project, let thread = currentThread, let scope = pullRequestScope, !prCI.reading else { return }
        prCI.reading = true
        defer { prCI.reading = false }
        if prCI.scope != scope {
            (prCI.ci, prCI.scope, prCI.readAt) = (.checking, scope, nil)
            applyPullRequestCI()
        }
        let before = prCI.readAt
        let read: PullRequestCI
        do { read = .known(try await actions.pullRequestStatus(project, thread)) } catch { read = .unavailable("\(error)") }
        // A merge that answered meanwhile is newer than this read.
        guard pullRequestScope == scope, prCI.readAt == before else { return }
        (prCI.ci, prCI.readAt) = (read, .now)
        applyPullRequestCI()
    }

    /// Puts what GitHub said into the thread on screen: the banner's CI, and the spine's Ship, PR review and Clean steps.
    func applyPullRequestCI() {
        guard let scope = pullRequestScope, prCI.scope == scope, let ci = prCI.ci, case .thread(var shown) = screen else { return }
        shown.ci = ci
        if let status = ci.status {
            let outcome: PullRequestOutcome =
                switch status.state {
                case .open: .open
                case .merged: .merged
                case .closed: .closed
                }
            shown.spine = ThreadSpine.derive(
                state: shown.state, approval: shown.approval, outcome: outcome,
                checks: status.checksError == nil ? status.checks : nil, currentHead: status.head)
            shown.attention = Attention.derive(spine: shown.spine, state: shown.state)
        }
        screen = .thread(shown)
    }

    /// Merges what the banner shows as green, at the commit it was green on. A refusal or a merge GitHub does not confirm is an
    /// error, and CI is read again so the banner shows what is true now, not a merge that did not happen.
    func mergePullRequest() async {
        guard let project, let thread = currentThread, case .thread(let shown) = screen, shown.canMerge,
            let status = shown.ci?.status, let scope = pullRequestScope, !deciding
        else { return }
        (actionError, notice) = (nil, nil)
        deciding = true
        defer { deciding = false }
        var merged = false
        await working("Merging PR #\(status.number)…") {
            do {
                let after = try await actions.mergePullRequest(project, thread, status.head)
                guard pullRequestScope == scope else { return }
                (prCI.ci, prCI.readAt) = (.known(after), .now)
                applyPullRequestCI()
                notice = "Merged PR #\(after.number)."
                merged = true
            } catch { if pullRequestScope == scope { actionError = "\(error)" } }
        }
        if !merged, pullRequestScope == scope { await refreshPullRequestCI() }
    }
}
