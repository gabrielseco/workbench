import Foundation
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

/// The decision card picks the next press from the same rules the step screens read.
@MainActor @Suite struct FeedActionsTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func snapshot(_ scenario: AppScenario) throws -> ThreadSnapshot {
        let name = "fa-\(scenario.rawValue)-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".workbench"), withIntermediateDirectories: true)
        let source = repositoryRoot.appendingPathComponent("Fixtures/app/\(scenario.rawValue)/threads")
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(".workbench/threads"))
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = ProjectLoader.load(project: Project(root: root)).screen
        guard case .thread(let shown) = screen else { throw FixtureError.notAThread }
        return shown
    }

    private enum FixtureError: Error { case notAThread }

    private func decide(_ snapshot: ThreadSnapshot, _ edit: (inout FeedActionContext) -> Void = { _ in }) -> FeedDecision {
        var context = FeedActionContext(snapshot: snapshot)
        edit(&context)
        return FeedActions.derive(context)
    }

    private func kinds(_ actions: [FeedAction]) -> [FeedAction.Kind] { actions.map(\.kind) }

    // MARK: The next press, per state

    @Test func aDraftGoalIsApprovedAndRunFromTheCard() throws {
        let shown = try snapshot(.draft)
        let decision = decide(shown) { $0.goalPill = .draft; $0.goalCanApprove = true }
        #expect(decision.primary?.kind == .approveAndRun && decision.primary?.enabled == true)
        #expect(kinds(decision.more) == [.newGoal], "the goal is edited on its own card")
        let blocked = decide(shown) { $0.goalPill = .draft; $0.goalCanApprove = false }
        #expect(blocked.primary?.kind == .approveAndRun)
        #expect(blocked.primary?.enabled == false, "the goal says it cannot be approved yet")
    }

    @Test func aDraftGoalCannotBeApprovedAgainWhileItsEditsAreBeingSaved() throws {
        let decision = decide(try snapshot(.draft)) {
            $0.goalPill = .draft
            $0.goalCanApprove = true
            $0.busy = true
        }
        #expect(decision.primary?.kind == .approveAndRun && decision.primary?.enabled == false)
    }

    @Test func anApprovedGoalWithNothingRunIsRun() throws {
        let decision = decide(try snapshot(.goalApproved)) { $0.goalPill = .approved; $0.goalCanApprove = true }
        #expect(decision.primary?.kind == .run && decision.primary?.enabled == true)
    }

    @Test func theSameReasonsDisableItAsOnTheGoalScreen() throws {
        let shown = try snapshot(.goalApproved)
        for (name, edit) in [
            ("busy", { (c: inout FeedActionContext) in c.busy = true }),
            ("starting", { (c: inout FeedActionContext) in c.starting = true }),
            ("a run already going", { (c: inout FeedActionContext) in c.runningHere = true }),
        ] {
            let decision = decide(shown) { c in
                c.goalPill = .approved
                c.goalCanApprove = true
                edit(&c)
            }
            #expect(decision.primary?.enabled == false, "\(name) disables Run")
        }
    }

    @Test func aTurnThatIsGoingOnIsStoppedFromTheCard() throws {
        var shown = try snapshot(.running)
        shown.run?.phase = .working
        let decision = decide(shown)
        #expect(decision.primary?.kind == .stopTurn && decision.primary?.title == "Stop turn")
        #expect(decide(shown) { $0.stopping = true }.primary?.title == "Stopping…")
        #expect(decide(shown) { $0.stopping = true }.primary?.enabled == false)
    }

    @Test func aTurnThatIsGoingOnOpensTheWorktreeNotADiff() throws {
        var shown = try snapshot(.running)
        shown.run?.phase = .working
        let open = try #require(decide(shown).secondary)
        #expect(open.kind == .openWorktree && open.enabled, "the worktree is there while the turn works")
        let menu = kinds(decide(shown).more)
        #expect(!menu.contains(.openDiff) && !menu.contains(.openWorktree), "no copy in the menu")
        #expect(decide(shown) { $0.busy = true }.secondary?.enabled == false)
        // A thread that has not started a turn has no worktree to read.
        var fresh = shown
        fresh.state.lastTurn = 0
        #expect(decide(fresh).secondary?.enabled == false)
    }

    @Test func aTurnWhoseRunnerIsGoneCanBeRunAgainAndASuccessfulOneCannot() throws {
        let gone = try snapshot(.running)
        #expect(gone.run?.phase == .orphaned && decide(gone).primary?.kind == .runAgain)
        #expect(decide(gone) { $0.runningHere = true }.primary == nil, "this app is running it")
        let failed = try {
            var shown = try snapshot(.running)
            shown.run?.phase = .ended(result: "timed_out", reason: nil)
            return shown
        }()
        #expect(decide(failed).primary?.kind == .runAgain)
    }

    @Test func aTurnAwaitingReviewIsAcceptedAndTheRestIsInTheMenu() throws {
        let shown = try snapshot(.needsYou)
        let decision = decide(shown) { $0.reviewShown = true; $0.reviewCanDecide = true; $0.reviewHasFiles = true }
        #expect(decision.primary?.kind == .accept && decision.primary?.enabled == true)
        #expect(kinds(decision.more).prefix(3) == [.reviewDetails, .sendBack, .discard])
        #expect(decision.secondary?.kind == .openDiff, "what changed is one plain button beside Accept, not in the menu")
        #expect(!kinds(decision.more).contains(.openDiff))
        #expect(decision.title == "Accept the work", "under NEXT the heading is the press, not the step's name")
        #expect(decision.more.first { $0.kind == .discard }?.destructive == true)
        let open = decide(shown) { $0.reviewShown = true; $0.reviewCanDecide = false }
        #expect(open.primary?.enabled == false, "criteria are still open")
        let deciding = decide(shown) { $0.reviewShown = true; $0.reviewCanDecide = true; $0.deciding = true }
        #expect(deciding.primary?.enabled == false)
        let noFiles = decide(shown) { $0.reviewShown = true; $0.reviewHasFiles = false }
        #expect(noFiles.secondary?.enabled == false)
    }

    @Test func theShippedPullRequestIsOnePlainButtonAwayWhateverTheNextStepIs() throws {
        var shipped = try snapshot(.prOpen)
        #expect(decide(shipped).secondary?.kind == .openPR && decide(shipped).secondary?.enabled == true)
        #expect(!decide(shipped).more.contains { $0.kind == .openPR })
        let green = PRStatus(
            number: 482, state: .open, head: String(repeating: "a", count: 40),
            checks: PRChecksSummary(checks: [PRCheck(name: "test", bucket: "pass")]), checksError: nil)
        shipped.ci = .known(green)
        #expect(decide(shipped).primary?.kind == .merge && decide(shipped).secondary?.kind == .openPR)
        #expect(decide(try snapshot(.accepted)).secondary == nil, "nothing is shipped yet")
    }

    @Test func anAcceptedThreadIsShippedAndAShippedOneIsReviewedThenMerged() throws {
        let accepted = try snapshot(.accepted)
        #expect(decide(accepted).primary?.kind == .ship && decide(accepted) { $0.deciding = true }.primary?.enabled == false)

        var shipped = try snapshot(.prOpen)
        #expect(shipped.watchesPullRequest)
        #expect(decide(shipped).primary?.kind == .reviewPR)
        let merge = decide(shipped).more.first { $0.kind == .merge }
        #expect(merge?.enabled == false, "no green CI has been read")

        let green = PRStatus(
            number: 482, state: .open, head: String(repeating: "a", count: 40),
            checks: PRChecksSummary(checks: [PRCheck(name: "test", bucket: "pass")]), checksError: nil)
        shipped.ci = .known(green)
        let ready = decide(shipped)
        #expect(ready.primary?.kind == .merge && ready.primary?.enabled == true)
        #expect(ready.more.contains { $0.kind == .reviewPR })
        #expect(decide(shipped) { $0.busy = true }.primary?.enabled == false)
    }

    @Test func aFinishedThreadOffersTheNextGoalOnly() throws {
        for scenario in [AppScenario.cleaned, .discarded] {
            let decision = decide(try snapshot(scenario))
            #expect(decision.primary?.kind == .newGoal && decision.more.isEmpty, "\(scenario.rawValue)")
        }
    }

    @Test func anAcceptedThreadKeepsItsWorktreeActionsUntilItIsDiscardedOrCleaned() throws {
        let accepted = decide(try snapshot(.accepted)) { $0.herdrFound = true }
        #expect(accepted.primary?.kind == .ship && kinds(accepted.more) == [.openWorktree, .openHerdr, .newGoal])
        let shipped = decide(try snapshot(.prOpen)) { $0.herdrFound = true }
        #expect(kinds(shipped.more).contains(.openWorktree) && kinds(shipped.more).contains(.openHerdr))
        let discarded = decide(try snapshot(.discarded))
        #expect(!kinds(discarded.more).contains(.openWorktree), "its worktree is gone")
        let cleaned = decide(try snapshot(.cleaned))
        #expect(!kinds(cleaned.more).contains(.openWorktree))
    }

    /// The card puts a button's title in its tooltip when it has no help of its own, so every button says what it does; the ones
    /// that act on something outside the window say so in their help.
    @Test func theButtonsThatOpenAnotherAppSayWhatTheyOpen() throws {
        let shown = try snapshot(.needsYou)
        let decision = decide(shown) { $0.reviewShown = true; $0.reviewHasFiles = true; $0.herdrFound = true }
        let all = decision.more + [decision.secondary].compactMap { $0 }
        let help = Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0.help ?? "") })
        #expect(help[.openDiff]?.contains("editor") == true)
        #expect(help[.openWorktree]?.contains("editor") == true)
        #expect(help[.openHerdr]?.contains("Herdr") == true)
        #expect(help[.discard]?.isEmpty == false && help[.sendBack]?.isEmpty == false)
    }

    @Test func everyStateHasAtMostOnePrimaryAndNoButtonTwice() throws {
        // The scenarios that open to a thread; the others (no project, no thread, a corrupt log) have no card to decide.
        let threadless: Set<AppScenario> = [.noThread, .corrupt, .tasks, .tasksEmpty, .draftGoal]
        var checked = 0
        defer { #expect(checked >= 8, "only \(checked) scenarios were checked") }
        for scenario in AppScenario.allCases where !threadless.contains(scenario) {
            let shown = try snapshot(scenario)
            checked += 1
            for review in [false, true] {
                let decision = decide(shown) { $0.reviewShown = review; $0.goalPill = .draft; $0.goalCanApprove = true }
                let all = [decision.primary, decision.secondary].compactMap { $0 } + decision.more
                #expect(Set(all.map(\.kind)).count == all.count, "\(scenario.rawValue) lists a button twice")
            }
        }
    }

    // MARK: What the card says

    @Test func theCardDoesNotRepeatTheStepUnderItsHeading() {
        let none = FeedDecision()
        #expect(DecisionCard.line(step: .review, why: "Review · turn 1 done", decision: none) == "turn 1 done")
        #expect(DecisionCard.line(step: .goal, why: "Writing", decision: none) == "Writing")
        #expect(DecisionCard.line(step: nil, why: "Nothing is left to do.", decision: none) == "Nothing is left to do.")
        #expect(DecisionCard.line(step: .review, why: "Review · x", decision: FeedDecision(why: "Own words")) == "Own words")
    }

    @Test func mergeSaysWhyItIsTheNextPressAndReviewDoesNot() throws {
        var shipped = try snapshot(.prOpen)
        #expect(decide(shipped).why == nil)
        let green = PRStatus(
            number: 482, state: .open, head: String(repeating: "a", count: 40),
            checks: PRChecksSummary(checks: [PRCheck(name: "test", bucket: "pass")]), checksError: nil)
        shipped.ci = .known(green)
        let ready = decide(shipped)
        #expect(ready.primary?.kind == .merge && ready.why?.contains("merged") == true)
    }

    @Test func aCleanReviewKeepsMergeAsTheButtonDisabledUntilCIIsGreen() throws {
        var shipped = try snapshot(.prOpen)
        let head = String(repeating: "a", count: 40)
        shipped.state.review.prReview = Review.PRReview(
            round: 1, pr: shipped.state.pullRequest?.number, headSHA: head, verdict: "clean", failure: nil, findingsPath: nil,
            costUSD: nil)
        func status(_ bucket: String) -> PRStatus {
            PRStatus(
                number: 482, state: .open, head: head, checks: PRChecksSummary(checks: [PRCheck(name: "test", bucket: bucket)]),
                checksError: nil)
        }
        shipped.ci = .checking
        var d = decide(shipped)
        #expect(d.primary?.kind == .merge && d.primary?.enabled == false && d.primary?.title == "Merge")
        shipped.ci = .known(status("pending"))
        d = decide(shipped)
        #expect(d.primary?.kind == .merge && d.primary?.enabled == false && d.primary?.title == "Merge")
        shipped.ci = .known(status("fail"))
        #expect(decide(shipped).primary?.enabled == false && decide(shipped).primary?.help == "CI failed.")
        shipped.ci = .known(status("pass"))
        d = decide(shipped)
        #expect(d.primary?.kind == .merge && d.primary?.enabled == true && d.primary?.title == "Merge")

        // Findings, or a review of an older commit, leave Review as the next press.
        shipped.ci = .known(status("pending"))
        shipped.state.review.prReview?.verdict = "fix"
        #expect(decide(shipped).primary?.kind == .reviewPR || decide(shipped).primary?.kind == .reviewAgain)
        shipped.state.review.prReview?.verdict = "clean"
        shipped.state.review.prReview?.headSHA = String(repeating: "b", count: 40)
        #expect(decide(shipped).primary?.kind != .merge)
        shipped.state.review.prReview?.headSHA = nil
        #expect(decide(shipped).primary?.kind != .merge, "a review with no recorded commit is not known to cover this one")
        shipped.state.review.prReview?.headSHA = head
        shipped.state.review.prReview?.pr = 1
        #expect(decide(shipped).primary?.kind != .merge, "a round of another pull request")
    }

    @Test func aPRReviewIsToldInTheStepScreensWords() {
        #expect(PRReviewRow.outcome(ok: true, verdict: "clean") == "clean")
        #expect(PRReviewRow.outcome(ok: true, verdict: "fix") == "findings to fix")
        #expect(PRReviewRow.outcome(ok: true, verdict: nil) == "no verdict")
        #expect(PRReviewRow.outcome(ok: false, verdict: nil) == "did not finish")
    }
}
