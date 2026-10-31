import Foundation
import WorkbenchCore

/// The shipped pull request's CI, read from GitHub while it is open, and Merge once it is green. Merging is only ever the person's
/// click: nothing here merges because CI turned green.
extension ProjectStore {
    /// The pull request on screen, as the scope its CI is kept for; nil when nothing shipped is shown.
    private var pullRequestScope: String? {
        guard case .thread(let shown) = screen, let pr = shown.state.pullRequest, !shown.state.cleaned,
            let scope = currentScope
        else { return nil }
        return "\(scope)#\(pr.number)"
    }

    /// Whether the poll should read CI now: never read for this pull request, or read long enough ago. Not once it has ended.
    var pullRequestCIIsDue: Bool {
        guard let scope = pullRequestScope, !readingPRCI, !deciding else { return false }
        guard prCIScope == scope, let ci = prCI, let readAt = prCIReadAt else { return true }
        if ci.ended { return false }
        return readAt.duration(to: .now) >= (ci.isPending ? ciIntervals.pending : ciIntervals.settled)
    }

    /// Reads the pull request's state and CI once. A failed read is shown as unavailable, never as the last good answer.
    func refreshPullRequestCI() async {
        guard let project, let thread = currentThread, let scope = pullRequestScope, !readingPRCI else { return }
        readingPRCI = true
        defer { readingPRCI = false }
        if prCIScope != scope {
            (prCI, prCIScope, prCIReadAt) = (.checking, scope, nil)
            applyPullRequestCI()
        }
        let (mine, before) = (generation, prCIReadAt)
        let read: PullRequestCI
        do { read = .known(try await actions.pullRequestStatus(project, thread)) } catch { read = .unavailable("\(error)") }
        // A merge that answered meanwhile is newer than this read.
        guard mine == generation, pullRequestScope == scope, prCIReadAt == before else { return }
        (prCI, prCIReadAt) = (read, .now)
        applyPullRequestCI()
    }

    /// Puts what GitHub said into the thread on screen: the banner's CI, and the spine's Ship, PR review and Clean steps.
    func applyPullRequestCI() {
        guard let scope = pullRequestScope, prCIScope == scope, let ci = prCI, case .thread(var shown) = screen else { return }
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
            let status = shown.ci?.status, !deciding
        else { return }
        (actionError, notice) = (nil, nil)
        deciding = true
        defer { deciding = false }
        let mine = generation
        var merged = false
        await working("Merging PR #\(status.number)…") {
            do {
                let after = try await actions.mergePullRequest(project, thread, status.head)
                guard mine == generation else { return }
                (prCI, prCIReadAt) = (.known(after), .now)
                applyPullRequestCI()
                notice = "Merged PR #\(after.number)."
                merged = true
            } catch { if mine == generation { actionError = "\(error)" } }
        }
        if !merged, mine == generation { await refreshPullRequestCI() }
    }
}
