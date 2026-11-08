import Foundation
import WorkbenchCore

/// Where "Fix failed tests" is, for the CI lines to say: reading CI, starting the fix, its turn, pushing it, done or why not.
struct CIFixProgress: Equatable {
    enum Phase: Equatable {
        case reading, starting, running, shipping, submitted
        case failed(String)
    }

    var phase: Phase
    /// The thread whose CI failed, and the follow-up that fixes it once there is one: the progress is shown on either.
    var parent: String
    var fix: String?
    /// The failed test checks it was started for.
    var tests: [String]
    var generation: Int

    /// Still going: a second press starts nothing.
    var active: Bool {
        switch phase {
        case .reading, .starting, .running, .shipping: true
        case .submitted, .failed: false
        }
    }

    /// The line the CI banner shows under its rows.
    var line: String {
        let names = tests.joined(separator: ", ")
        return switch phase {
        case .reading: "Fixing \(names): reading why CI failed…"
        case .starting: "Fixing \(names): starting the fix…"
        case .running: "Fixing \(names): the agent is working on it…"
        case .shipping: "Fixing \(names): accepting the fix and pushing it to the pull request…"
        case .submitted: "Fix pushed to the pull request. CI runs again on it; Merge waits until it is green."
        case .failed(let why): "The fix for \(names) did not go through: \(why)"
        }
    }

    var failed: Bool { if case .failed = phase { true } else { false } }
}

/// "Fix failed tests": when the pull request's CI says a test failed, the click is the yes. It reads what CI says of the failed tests,
/// starts core's follow-up on the pull request's branch with that as its goal (the same follow-up a review round starts, so it
/// counts against `[pr_review] max_rounds`), runs its turn, and when the turn and the check pass accepts it, pushes it to the same
/// pull request and reads CI again. It never merges: Merge stays the person's click, offered only once CI is green.
extension ProjectStore {
    /// Whether the fix is going for the thread on screen or any other: one at a time.
    var ciFixing: Bool { ciFix?.active == true && ciFix?.generation == generation }

    /// The progress to show on `thread`'s screen: it is the thread the fix was started from or the fix itself.
    func ciFixShown(on thread: String?) -> CIFixProgress? {
        guard let fix = ciFix, fix.generation == generation, let thread else { return nil }
        return fix.parent == thread || fix.fix == thread ? fix : nil
    }

    func fixFailedTests() async {
        guard let project, let thread = currentThread, case .thread(let shown) = screen, shown.watchesPullRequest,
            let ci = shown.ci, let pr = ci.status?.number, !ci.failedTests.isEmpty, !ciFixing, !starting, busy == nil,
            fixRoundToShip == nil
        else { return }
        let mine = generation
        ciFix = CIFixProgress(phase: .reading, parent: thread, tests: ci.failedTests, generation: mine)
        func fail(_ why: String) {
            guard mine == generation else { return }
            ciFix?.phase = .failed(why)
        }
        var made: String?
        var ran = false
        await working("Reading why the tests failed…") {
            ran = true
            do {
                let failures = try await actions.failedTests(project, thread)
                guard mine == generation else { return }
                guard !failures.isEmpty else { return fail("\(CIFixError.noFailedTests)") }
                ciFix?.tests = failures.map(\.name)
                ciFix?.phase = .starting
                nowWorking("Starting the fix…")
                let plan = try await actions.followUpPlan(project, thread, pr)
                guard mine == generation else { return }
                if let refusal = plan.refusal { return fail(refusal) }
                made = try await actions.startCIFix(project, thread, failures, plan.budget)
            } catch {
                fail("\(error) Fix the cause, then press Fix failed tests again.")
            }
        }
        // Another action held the window: nothing was asked of CI, so there is nothing to say.
        if !ran, mine == generation { ciFix = nil }
        guard let id = made, mine == generation else { return }
        ciFix?.fix = id
        ciFix?.phase = .running
        await reload()
        guard mine == generation else { return }
        fixRoundToShip = FixRound(thread: id, reviewRound: 0, generation: mine, kind: .failedTests)
        startRun(project, id, generation: mine)
        if !ownedRuns.contains(where: { $0.project == project && $0.thread == id }) {
            fixRoundToShip = nil
            fail("its thread \(id) was made, but its turn did not start. Open it and press Run again.")
        }
    }

    /// What follows a CI fix round's push: the pull request's CI read again, so the banner shows the new run, not the failed one.
    func ciFixSubmitted(_ round: FixRound) async {
        guard round.generation == generation else { return }
        ciFix?.phase = .submitted
        await refreshPullRequestCI()
    }

    /// Says on the CI lines why a CI fix round stopped; a review fix round says it in the notice alone.
    func ciFixStopped(_ round: FixRound, _ why: String) {
        guard round.kind == .failedTests, round.generation == generation, ciFix?.fix == round.thread else { return }
        ciFix?.phase = .failed(why)
    }
}
