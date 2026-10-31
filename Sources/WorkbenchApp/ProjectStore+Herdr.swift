import Foundation
import WorkbenchCore

/// What the last "Run in Herdr" did, as the goal screen says it.
enum HerdrHandoffOutcome: Equatable {
    /// Herdr made a space for the worktree and Claude was started there on the goal.
    case sent(space: String)
    /// The worktree had a space already: it was brought forward and the goal was not sent a second time.
    case alreadyOpen(space: String)
    /// No Herdr to hand to: none found, or its window could not be opened.
    case unavailable(String)
    /// Herdr, or the approval and worktree before it, refused or did not answer.
    case failed(String)

    var text: String {
        switch self {
        case .sent(let space): "Sent to Herdr (space \(space)): Claude is working on the goal in this thread's worktree."
        case .alreadyOpen: "Herdr already had this worktree open: brought forward, and the goal was not sent again."
        case .unavailable(let why): "Herdr is unavailable: \(why)"
        case .failed(let why): "The goal was not handed to Herdr: \(why)"
        }
    }

    var isProblem: Bool {
        switch self {
        case .sent, .alreadyOpen: false
        case .unavailable, .failed: true
        }
    }

    init(_ error: Error) {
        switch error {
        case is GoalActions.HerdrNotFound: self = .unavailable("\(error)")
        case let failure as HerdrFailure where failure.windowDown || failure.code == "launch_failed":
            self = .unavailable(failure.message)
        default: self = .failed("\(error)")
        }
    }
}

/// A handoff outcome with the project and thread it was about, so another thread on screen does not show it.
struct HerdrHandoffShown: Equatable {
    var scope: String?
    var outcome: HerdrHandoffOutcome
}

extension ProjectStore {
    /// "Open in Herdr": the thread's worktree as a Herdr space, brought forward. Herdr's own refusal is the error line.
    func openInHerdr() async {
        guard let project, let thread = currentThread else { return }
        (actionError, actionNote) = (nil, nil)
        let mine = generation
        await working("Opening in Herdr…") {
            do {
                let opened = try await actions.openInHerdr(project, thread)
                guard mine == generation else { return }
                actionNote = opened.alreadyOpen ? "Herdr already had it open: brought forward." : "Opened in Herdr."
            } catch { if mine == generation { actionError = "\(error)" } }
        }
    }

    /// The last handoff's outcome, for the thread on screen only.
    var herdrHandoffOutcome: HerdrHandoffOutcome? {
        herdrHandoff.flatMap { $0.scope == currentScope ? $0.outcome : nil }
    }

    /// "Run in Herdr" on the goal screen: the goal goes to a Claude session in Herdr instead of a run of this app.
    func runGoalInHerdr() async {
        guard let project, let thread = currentThread, !starting, !runningHere else { return }
        // Changes already made to the goal are written first, so what is approved is what the window shows.
        await goalEdits?.value
        (actionError, actionNote, herdrHandoff) = (nil, nil, nil)
        let (mine, scope) = (generation, currentScope)
        await working("Handing the goal to Herdr…") {
            let outcome: HerdrHandoffOutcome
            do {
                let handoff = try await actions.runGoalInHerdr(project, thread)
                outcome = handoff.alreadyOpen ? .alreadyOpen(space: handoff.space) : .sent(space: handoff.space)
            } catch { outcome = HerdrHandoffOutcome(error) }
            guard mine == generation else { return }
            herdrHandoff = HerdrHandoffShown(scope: scope, outcome: outcome)
        }
        // The approval and the worktree are in the log now, whatever Herdr said.
        await reload()
    }
}
