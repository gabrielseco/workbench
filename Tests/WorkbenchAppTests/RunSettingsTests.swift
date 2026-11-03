import AppKit
import SwiftUI
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptRunSettingsFixtures: [AppFixture] = []

/// The Run settings inspector (P22 slice 3c): where it goes, what it lists, and that it writes the edits the Goal screen writes.
@MainActor @Suite struct RunSettingsTests {
    private final class Edits: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [GoalEdit] = []
        func add(_ edit: GoalEdit) { lock.withLock { all.append(edit) } }
        var seen: [GoalEdit] { lock.withLock { all } }
    }

    private func store(approved: Bool = false, turn: Bool = false, edits: Edits = Edits()) async throws -> (ProjectStore, Edits) {
        let fixture = try await AppFixture()
        keptRunSettingsFixtures.append(fixture)
        try await fixture.addThread("t1", approved: approved)
        if turn { try fixture.turn("t1", 1) }
        let actions = GoalActions(editGoal: { _, _, edit in edits.add(edit) })
        let preferences = MemoryPreferences()
        preferences.chatFeed = true
        let store = ProjectStore(preferences: preferences, actions: actions)
        #expect(await store.open(fixture.root))
        return (store, edits)
    }

    // MARK: The switch and the layout

    @Test func theInspectorIsOpenUntilAPersonClosesItAndTheirChoiceIsRemembered() {
        let suite = "runsettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsPreferences(defaults: defaults)
        #expect(preferences.runSettings && MemoryPreferences().runSettings, "unset is on: the artboard shows it open")
        #expect(!preferences.runSettingsChosen && !MemoryPreferences().runSettingsChosen)
        let store = ProjectStore(preferences: preferences)
        #expect(store.runSettingsOn && !store.runSettingsChosen)
        store.setRunSettings(false)
        #expect(!store.runSettingsOn && store.runSettingsChosen && !UserDefaultsPreferences(defaults: defaults).runSettings)
        let next = ProjectStore(preferences: UserDefaultsPreferences(defaults: defaults))
        #expect(!next.runSettingsOn && next.runSettingsChosen, "closed stays closed at the next launch")
        store.setRunSettings(true)
        #expect(UserDefaultsPreferences(defaults: defaults).runSettings)
        #expect(ProjectStore(preferences: UserDefaultsPreferences(defaults: defaults)).runSettingsOn)
        let memory = MemoryPreferences()
        memory.runSettings = false
        #expect(!memory.runSettings && memory.runSettingsChosen)
    }

    @Test func theVerifierAndTheJudgeSayWhatTheyDoAndAReviewStageSaysNothing() {
        #expect(RunSettingsLayout.description(forStep: "verifier") == "Drives the app from the request and posts screenshots.")
        #expect(RunSettingsLayout.description(forStep: "judge") == "Checks the work against your criteria. Needs at least one.")
        #expect(RunSettingsLayout.description(forStep: "design") == nil, "a project's own review stage has no line of ours")
    }

    @Test func theFootNamesWhereTheGoalIsSaved() {
        var goal = GoalModel.invalid(path: ".workbench/threads/g-1/goal.md", problems: [])
        goal.path = ".workbench/threads/g-1/goal.md"
        #expect(RunSettingsLayout.savedTo(goal) == "Saved to .workbench/threads/g-1/goal.md")
        #expect(RunSettingsLayout.width == 300)
    }

    @Test func theHeadersButtonOpensWhatIsNotShownAndClosesWhatIs() {
        func sets(_ on: Bool, _ chosen: Bool, _ fits: Bool) -> Bool {
            RunSettingsLayout.toggled(on: on, chosen: chosen, fits: fits)
        }
        #expect(!sets(true, false, true), "the default shown beside the feed: the click closes it")
        #expect(sets(true, false, false), "the default in a narrow window shows nothing: the first click opens it")
        #expect(!sets(true, true, false), "chosen and shown over the feed: the click closes it")
        #expect(sets(false, true, true) && sets(false, true, false), "closed: the click opens it")
    }

    @Test func theHeaderAndTheMenuShortcutShareOneToggleSoThePressThatShowsNothingOpensIt() {
        let narrow = ProjectStore(preferences: MemoryPreferences())
        narrow.runSettingsFits = false
        #expect(!narrow.runSettingsShowing, "the default shows nothing in a narrow window")
        narrow.toggleRunSettings()
        #expect(narrow.runSettingsShowing && narrow.runSettingsChosen, "the first press opens it")
        narrow.toggleRunSettings()
        #expect(!narrow.runSettingsShowing)
        let wide = ProjectStore(preferences: MemoryPreferences())
        wide.runSettingsFits = true
        #expect(wide.runSettingsShowing, "the default is open where it fits")
        wide.toggleRunSettings()
        #expect(!wide.runSettingsShowing && wide.runSettingsChosen, "the first press closes it")
    }

    @Test func theDefaultOpensItOnlyBesideTheFeedNeverOverItUntilAPersonHasChosen() {
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(store.runSettingsOn && !store.runSettingsChosen, "on by default, not chosen: a narrow window shows no sheet")
        store.setRunSettings(true)
        #expect(store.runSettingsChosen, "choosing it, even to keep it open, lets a narrow window show it")
    }

    @Test func aNarrowWindowOpensItOverTheFeedAndAWideOneBesideIt() {
        #expect(RunSettingsLayout.placement(centreWidth: 679) == .sheet, "the 900-wide minimum leaves the centre 679")
        #expect(RunSettingsLayout.placement(centreWidth: 899) == .sheet)
        #expect(RunSettingsLayout.placement(centreWidth: 900) == .beside)
        #expect(RunSettingsLayout.placement(centreWidth: 1_379) == .beside, "a 1600-wide window")
        #expect(RunSettingsLayout.width == 300)
        #expect(RunSettingsLayout.besideFrom - RunSettingsLayout.width >= 600, "the feed keeps a usable width beside it")
    }

    @Test func theToolsListIsTenAndHowManyMoreAndMarksTheGrantedOnes() {
        let allowed = (1...8).map { "tool\($0)" }
        let short = RunSettingsLayout.tools(allowed: allowed, granted: [])
        #expect(short.shown == allowed && short.more == 0)
        let long = RunSettingsLayout.tools(allowed: allowed, granted: ["Bash(git push)", "Bash(rm)", "Bash(ls)"])
        #expect(long.shown.count == 10 && long.more == 1)
        #expect(long.shown.contains("Bash(git push) (granted)"))
    }

    // MARK: The edits it writes are the Goal screen's

    @Test func theSwitchesAndTheFoldersBuildTheEditsTheGoalScreenBuilds() {
        var goal = GoalModel.invalid(path: "/tmp/goal.md", problems: [])
        goal.steps = [
            GoalModel.Step(name: "verifier", label: "Verifier", skipped: false, known: true),
            GoalModel.Step(name: "judge", label: "Judge", skipped: true, known: true),
        ]
        #expect(goal.togglingSkip("verifier") == .setSkip(["judge", "verifier"]), "turning one off keeps the others as they are")
        #expect(goal.togglingSkip("judge") == .setSkip([]), "turning the judge back on")
        goal.goalReadAlso = ["../backend", "../shared"]
        #expect(goal.addingReadAlso("~/docs") == .setReadAlso(["../backend", "../shared", "~/docs"]))
        #expect(goal.removingReadAlso("../backend") == .setReadAlso(["../shared"]))
        #expect(goal.removingReadAlso("../gone") == nil, "the goal no longer has it")
    }

    @Test func theOutOfScopeEditsBuildWhatTheGoalScreenBuilds() {
        var goal = GoalModel.invalid(path: "/tmp/goal.md", problems: [])
        goal.outOfScope = ["the timeout", "uploads"]
        #expect(goal.addingOutOfScope("the UI") == .setOutOfScope(["the timeout", "uploads", "the UI"]))
        #expect(goal.replacingOutOfScope("uploads", with: "downloads") == .setOutOfScope(["the timeout", "downloads"]))
        #expect(goal.removingOutOfScope("the timeout") == .setOutOfScope(["uploads"]))
        #expect(goal.replacingOutOfScope("gone", with: "x") == nil && goal.removingOutOfScope("gone") == nil)
    }

    @Test func aSwitchWritesTheSkipEditThroughTheSameStoreActionAsTheGoalScreen() async throws {
        let (store, edits) = try await store()
        let judge = try #require(store.goal?.steps.first { $0.name == "judge" })
        #expect(store.goal?.editable == true)
        await store.editGoal { $0.togglingSkip(judge.name) }
        #expect(edits.seen == [.setSkip(["judge"])])
        await store.editGoal { $0.addingReadAlso("../backend") }
        #expect(edits.seen.last == .setReadAlso(["../backend"]))
    }

    /// The editor blocks write through the store the way the switches do: each edit reaches the fake action as the Goal screen builds it.
    @Test func theEditorBlocksWriteTheirEditsThroughTheStore() async throws {
        let (store, edits) = try await store()
        await store.editGoal(.setRequest("Retry the client."))
        await store.editGoal(.addCriterion(text: "It retries", proof: "test: Client/retries"))
        await store.editGoal(.updateCriterion(id: "c1", text: "It still works", proof: nil))
        await store.editGoal(.removeCriterion(id: "c1"))
        let existing = store.goal?.outOfScope ?? []
        await store.editGoal { $0.addingOutOfScope("the timeout") }
        if let first = existing.first { await store.editGoal { $0.removingOutOfScope(first) } }
        #expect(edits.seen.prefix(4) == [
            .setRequest("Retry the client."), .addCriterion(text: "It retries", proof: "test: Client/retries"),
            .updateCriterion(id: "c1", text: "It still works", proof: nil), .removeCriterion(id: "c1"),
        ])
        #expect(edits.seen[4] == .setOutOfScope(existing + ["the timeout"]))
    }

    @Test func onlyADraftGoalCanBeEditedAndAGoalThatHasRunIsReadOnly() async throws {
        let (draft, _) = try await store()
        #expect(draft.goal?.editable == true)
        let (approved, _) = try await store(approved: true)
        #expect(approved.goal?.editable == false, "an approved goal is changed in the goal file")
        let (ran, _) = try await store(approved: true, turn: true)
        #expect(ran.goal?.editable == false)
        #expect(RunSettingsLayout.note(goal: try #require(draft.goal), lastTurn: 0) == nil)
        #expect(RunSettingsLayout.note(goal: try #require(approved.goal), lastTurn: 0) == RunSettingsLayout.draftNote)
        #expect(RunSettingsLayout.note(goal: try #require(ran.goal), lastTurn: 1) == RunSettingsLayout.ranNote)
    }

    /// The core refuses an edit only for a decided thread or a live runner, so a draft that a turn has run, or one an approval or another
    /// action is working on, is kept read-only by the window.
    @Test func aDraftThatHasRunOrIsBeingWorkedOnIsNotEdited() async throws {
        let (fresh, _) = try await store()
        guard case .thread(let snapshot) = fresh.screen, let goal = fresh.goal else { throw Failure.notAThread }
        #expect(fresh.goalEditable(snapshot, goal: goal))
        var ran = snapshot
        ran.state.lastTurn = 1
        #expect(!fresh.goalEditable(ran, goal: goal), "a turn has run")
        let working = Task { await fresh.working("Opening in Herdr…") { try? await Task.sleep(for: .milliseconds(400)) } }
        for _ in 0..<100 where fresh.busy == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!fresh.goalEditable(snapshot, goal: goal), "an action is going")
        await working.value
        #expect(fresh.goalEditable(snapshot, goal: goal))
    }

    @Test func theRunInHerdrButtonFollowsTheGoalScreensRules() async throws {
        let (draft, _) = try await store()
        guard case .thread(let fresh) = draft.screen, let goal = draft.goal else { throw Failure.notAThread }
        #expect(draft.canRunGoalInHerdr(fresh, goal: goal))
        let (ran, _) = try await store(approved: true, turn: true)
        guard case .thread(let after) = ran.screen, let ranGoal = ran.goal else { throw Failure.notAThread }
        #expect(!ran.canRunGoalInHerdr(after, goal: ranGoal) || ran.goalRunDisabled(after, goal: ranGoal))
        #expect(ran.goalRunDisabled(after, goal: ranGoal), "a turn has run")
    }

    private enum Failure: Error { case notAThread }

    // MARK: What it draws

    private func image<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws -> CGImage {
        let framed = view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.feedDrawsEagerly, true)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    private func differs(
        _ first: some View, _ second: some View, _ what: String, width: CGFloat = 260, height: CGFloat = 700
    ) throws {
        let x = try image(first, width: width, height: height)
        let y = try image(second, width: width, height: height)
        #expect(x.dataProvider?.data != y.dataProvider?.data, "\(what) is not drawn")
    }

    @Test func theInspectorDrawsTheGoalsSettingsAndSaysWhenThereIsNoGoal() async throws {
        let (store, _) = try await store()
        guard case .thread(let shown) = store.screen else { throw Failure.notAThread }
        try differs(
            RunSettingsInspector(snapshot: shown, goal: store.goal, store: store),
            RunSettingsInspector(snapshot: shown, goal: nil, store: store), "the settings")
        var limits = store.goal
        limits?.model = "opus"
        try differs(
            RunSettingsInspector(snapshot: shown, goal: store.goal, store: store),
            RunSettingsInspector(snapshot: shown, goal: limits, store: store), "the limits")
        var sheet = store.goal
        sheet?.grantedTools = ["Bash(git status)"]
        try differs(
            RunSettingsInspector(snapshot: shown, goal: store.goal, store: store),
            RunSettingsInspector(snapshot: shown, goal: sheet, store: store), "a granted tool")
        var folders = store.goal
        folders?.goalReadAlso = ["../backend"]
        try differs(
            RunSettingsInspector(snapshot: shown, goal: store.goal, store: store),
            RunSettingsInspector(snapshot: shown, goal: folders, store: store), "a reference folder")
        let (approved, _) = try await self.store(approved: true)
        guard case .thread(let approvedShown) = approved.screen else { throw Failure.notAThread }
        try differs(
            RunSettingsInspector(snapshot: shown, goal: store.goal, store: store),
            RunSettingsInspector(snapshot: approvedShown, goal: approved.goal, store: approved), "the read-only note")
    }

    /// In the sheet the feed, where an action's error is a row, is behind it: the column says what the action said.
    @Test func theSheetShowsWhatAnActionSaidAndTheColumnBesideTheFeedDoesNot() async throws {
        let (store, _) = try await store()
        guard case .thread(let shown) = store.screen else { throw Failure.notAThread }
        func drawn(messages: Bool) throws -> Data? {
            let view = RunSettingsInspector(snapshot: shown, goal: store.goal, store: store, showsMessages: messages)
            return try image(view, width: 260, height: 700).dataProvider?.data as Data?
        }
        let (sheetQuiet, besideQuiet) = (try drawn(messages: true), try drawn(messages: false))
        store.actionError = "the editor did not start"
        let (sheetSaid, besideSaid) = (try drawn(messages: true), try drawn(messages: false))
        #expect(sheetQuiet != sheetSaid, "the sheet shows the error")
        #expect(besideQuiet == besideSaid, "beside the feed the message is the feed's row, not drawn twice")
    }

    @Test func aWideWindowDrawsTheInspectorBesideTheFeed() async throws {
        let (store, _) = try await store()
        guard case .thread(let shown) = store.screen else { throw Failure.notAThread }
        var feed = shown
        feed.feed = [FeedItem(id: "n", seq: 1, turn: 0, kind: .next(step: .goal, why: "Writing"))]
        let on = MemoryPreferences()
        on.chatFeed = true
        on.runSettings = true
        let off = MemoryPreferences()
        off.chatFeed = true
        off.runSettings = false
        let project = Project(root: URL(fileURLWithPath: "/tmp/x"))
        let showing = ProjectStore(preferences: on, screen: .thread(feed), project: project)
        let hidden = ProjectStore(preferences: off, screen: .thread(feed), project: project)
        try differs(RootView(store: showing), RootView(store: hidden), "the inspector at 1400 wide", width: 1_400, height: 800)
    }

    @Test func theInspectorLeavesTheWorktreeToTheStepMenuOnceTheThreadHasRun() {
        var state = ThreadState.derive(from: [], id: "t1")
        #expect(!RunSettingsLayout.hasWorktree(state), "no turn yet: the goal file is all there is")
        state.lastTurn = 1
        #expect(RunSettingsLayout.hasWorktree(state))
        state.decision = "discarded"
        #expect(!RunSettingsLayout.hasWorktree(state), "the worktree is gone")
        state.decision = "accepted"
        #expect(RunSettingsLayout.hasWorktree(state))
        state.cleaned = true
        #expect(!RunSettingsLayout.hasWorktree(state))
    }
}
