import AppKit
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// The chat feed preview (P22 slice 3a): the switch, what the loader derives for it, and that every row and every fixture scenario draws.
@MainActor private var keptFeedFixtures: [AppFixture] = []

// One suite for the feed's drawing: its helpers (render, compare, save) are shared by every test in it.
// swiftlint:disable:next type_body_length
@MainActor @Suite struct FeedScreenTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["WORKBENCH_RENDER_DIR"]
        return URL(fileURLWithPath: path ?? NSTemporaryDirectory()).appendingPathComponent("workbench-app-renders")
    }

    private func image<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool, eager: Bool = true) throws -> CGImage {
        // A window background, as the real window has: without one, black text on nothing is one colour and reads as blank.
        let framed = view.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.feedDrawsEagerly, eager)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    private func distinctColours(_ image: CGImage) -> Int {
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var seen = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seen.insert(UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]))
            if seen.count > 64 { break }
        }
        return seen.count
    }

    private func save(_ image: CGImage, _ name: String) throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try #require(png).write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
    }

    // MARK: The switch

    @Test func theFeedIsOffUntilAPersonTurnsItOnAndItIsRemembered() {
        let suite = "feed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UserDefaultsPreferences(defaults: defaults)
        #expect(!preferences.chatFeed)
        preferences.chatFeed = true
        #expect(UserDefaultsPreferences(defaults: defaults).chatFeed)
        #expect(!MemoryPreferences().chatFeed)
    }

    @Test func aLaunchCanShowTheFeedWithoutTouchingThePreference() {
        let on = LaunchOptions.from(environment: ["WORKBENCH_APP_PROJECT": "/tmp/p", "WORKBENCH_CHAT_FEED": "1"])
        #expect(on.chatFeed && on.project != nil)
        #expect(!LaunchOptions.from(environment: ["WORKBENCH_APP_PROJECT": "/tmp/p"]).chatFeed)
        #expect(on.makeStore(preferences: MemoryPreferences()).chatFeedOn)
        #expect(!LaunchOptions.from(environment: [:]).makeStore(preferences: MemoryPreferences()).chatFeedOn)
    }

    // MARK: What the loader derives

    @Test func theLoaderDerivesTheFeedOnlyWhenAskedAndReadsTheLogOnce() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        let log = fixture.project.eventsURL("t1")

        let start = EventLogReadCount.reads(of: log)
        guard case .thread(let plain) = ProjectLoader.load(project: fixture.project).screen else { throw LoadError.notAThread }
        let plainReads = EventLogReadCount.reads(of: log) - start
        #expect(plain.feed.isEmpty && plainReads >= 1)

        let middle = EventLogReadCount.reads(of: log)
        guard case .thread(let withFeed) = ProjectLoader.load(project: fixture.project, feed: true).screen else {
            throw LoadError.notAThread
        }
        #expect(!withFeed.feed.isEmpty)
        #expect(EventLogReadCount.reads(of: log) - middle == plainReads, "the feed is derived from the read the load already did")
        #expect(withFeed.feed.contains { if case .goalCard = $0.kind { true } else { false } })
        #expect(withFeed.feed.contains { if case .turn = $0.kind { true } else { false } })
        #expect(withFeed.feed.last.map { if case .next = $0.kind { true } else { false } } == true)
    }

    @Test func turningTheFeedOnReadsTheThreadAgainAndOffPutsTheStepScreensBack() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let preferences = MemoryPreferences()
        let store = ProjectStore(preferences: preferences)
        #expect(await store.open(fixture.root))
        guard case .thread(let off) = store.screen else { throw LoadError.notAThread }
        #expect(off.feed.isEmpty && !store.chatFeedOn)

        await store.setChatFeed(true)
        #expect(preferences.chatFeed && store.chatFeedOn)
        guard case .thread(let on) = store.screen else { throw LoadError.notAThread }
        #expect(!on.feed.isEmpty)

        await store.setChatFeed(false)
        guard case .thread(let again) = store.screen else { throw LoadError.notAThread }
        #expect(again.feed.isEmpty && !preferences.chatFeed)
    }

    // MARK: Every row draws

    private static let samples: [(String, FeedItem.Kind)] = [
        ("user-note", .userNote(text: "Please retry the second file and keep the first as it is.")),
        ("goal-card", .goalCard(title: "Add retry with backoff", approval: .approved, criteria: 3, hash: "3f2a9c1d77")),
        ("goal-card-stale", .goalCard(title: "Add retry with backoff", approval: .stale, criteria: 3, hash: nil)),
        ("turn-working", .turn(number: 2, phase: .working, durationMs: nil, costUSD: nil)),
        ("turn-ended", .turn(number: 1, phase: .ended(result: "succeeded"), durationMs: 252_000, costUSD: 1.88)),
        ("turn-failed", .turn(number: 1, phase: .ended(result: "timed_out"), durationMs: 1_800_000, costUSD: nil)),
        ("turn-orphaned", .turn(number: 3, phase: .orphaned, durationMs: nil, costUSD: nil)),
        ("turn-unrecorded", .turn(number: 3, phase: .unrecorded, durationMs: nil, costUSD: nil)),
        ("agent-text", .agentText("Reading the client before changing how it retries.")),
        ("tool-group", .toolGroup(count: 14, summaries: ["Read Sources/Client.swift", "Grep retry", "Bash swift build"])),
        ("edit", .edit(file: "Sources/Thread/AutoAdvance.swift", tool: "Edit")),
        ("denied", .denied(tool: "Bash", input: "git push origin main")),
        ("check-passed", .check(result: "passed", command: "swift test", durationMs: 48_000)),
        ("check-failed", .check(result: "failed", command: "swift test", durationMs: 12_000)),
        ("judge-agrees", .judge(ok: true, criteria: 5, unmet: 0, concerns: 0)),
        ("judge-disagrees", .judge(ok: true, criteria: 5, unmet: 2, concerns: 1)),
        ("judge-silent", .judge(ok: false, criteria: 0, unmet: 0, concerns: 0)),
        ("verify-passed", .verify(ok: true, reason: nil, proofs: ["list-states.png", "feed.png"])),
        ("verify-failed", .verify(ok: false, reason: "the app did not start", proofs: [])),
        ("decision", .decision("accepted")),
        ("pull-request", .pullRequest(number: 482, url: "https://github.com/example/repo/pull/482")),
        ("pr-review", .prReview(round: 1, verdict: "findings", ok: true)),
        ("next", .next(step: .review, why: "Needs you · Review · turn 1 done")),
        ("next-done", .next(step: nil, why: "Nothing is left to do.")),
        ("notice-folded", .notice(.activityFolded(count: 950, refusals: 3))),
        ("notice-damaged", .notice(.logDamaged(problems: 2, first: "line 14 is not a valid event"))),
        ("notice-stale", .notice(.goalChangedSinceApproval)),
        ("notice-earlier", .notice(.earlierNotShown(count: 40))),
        ("notice-tail", .notice(.logTailCut)),
        ("notice-not-stored", .notice(.activityNotStored(count: 120))),
    ]

    @Test func everyKindOfRowDrawsInLightAndDark() throws {
        for (name, kind) in Self.samples {
            let item = FeedItem(id: name, seq: 1, turn: 1, kind: kind)
            for dark in [false, true] {
                let drawn = try image(FeedRow(item: item).padding(20), width: 640, height: 120, dark: dark)
                #expect(distinctColours(drawn) > 2, "\(name) \(dark ? "dark" : "light") came out blank")
                if name == "turn-ended" || name == "denied" || name == "next" || name == "goal-card" {
                    try save(drawn, "feed-row-\(name)-\(dark ? "dark" : "light")")
                }
            }
        }
    }

    /// Every kind of the core's feed has a sample here: a new kind that is not drawn fails this, not a user.
    @Test func everyKindHasASample() {
        var seen = Set<String>()
        for (_, kind) in Self.samples { seen.insert(String("\(kind)".prefix { $0 != "(" })) }
        #expect(
            seen == [
                "userNote", "goalCard", "turn", "agentText", "toolGroup", "edit", "denied", "check", "judge", "verify",
                "decision", "pullRequest", "prReview", "next", "notice",
            ])
    }

    // MARK: Whole window

    private func project(for scenario: AppScenario) throws -> Project {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-\(scenario.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".workbench"), withIntermediateDirectories: true)
        let source = repositoryRoot.appendingPathComponent("Fixtures/app/\(scenario.rawValue)")
        let threads = root.appendingPathComponent(".workbench/threads")
        if FileManager.default.fileExists(atPath: source.appendingPathComponent("threads").path) {
            try FileManager.default.copyItem(at: source.appendingPathComponent("threads"), to: threads)
        } else {
            try FileManager.default.createDirectory(at: threads, withIntermediateDirectories: true)
        }
        return Project(root: root)
    }

    @Test func everyScenarioDrawsWithTheFeedOnAtTheMinimumSizeAndARoomyOne() throws {
        for scenario in AppScenario.allCases {
            let project = try project(for: scenario)
            defer { try? FileManager.default.removeItem(at: project.root) }
            let loaded = ProjectLoader.load(project: project, feed: true)
            let preferences = MemoryPreferences()
            preferences.chatFeed = true
            let store = ProjectStore(preferences: preferences, screen: loaded.screen, project: project)
            for (width, height) in [(900.0, 600.0), (1100.0, 700.0)] {
                for dark in [false, true] {
                    let drawn = try image(RootView(store: store), width: width, height: height, dark: dark)
                    #expect(distinctColours(drawn) > 8, "\(scenario.rawValue) \(Int(width)) \(dark) came out blank")
                    if width == 1100 { try save(drawn, "feed-\(scenario.rawValue)-\(dark ? "dark" : "light")") }
                }
            }
        }
    }

    /// What this proves is that a thousand rows do not hang or break the window. `ImageRenderer` cannot draw a scroll view's content, so
    /// that the list is lazy, follows the newest row and keeps its place is checked by eye in the live app, not here.
    @Test func aThousandRowsDoNotBreakTheMinimumWindow() throws {
        let fixtureItems = (0..<1_000).map {
            FeedItem(id: "\($0)", seq: $0, turn: 1, kind: .agentText("step \($0): reading the file"))
        }
        var snapshot = try thread(.needsYou)
        snapshot.feed = fixtureItems
        let preferences = MemoryPreferences()
        preferences.chatFeed = true
        let project = Project(root: URL(fileURLWithPath: "/tmp/x"))
        let store = ProjectStore(preferences: preferences, screen: .thread(snapshot), project: project)
        // The real list, not the eager one the other renders use.
        let drawn = try image(RootView(store: store), width: 900, height: 600, dark: false, eager: false)
        #expect(drawn.width == 900 && drawn.height == 600 && distinctColours(drawn) > 8)
        try save(drawn, "feed-1000-rows-900x600")
    }

    private func thread(_ scenario: AppScenario) throws -> ThreadSnapshot {
        let project = try project(for: scenario)
        defer { try? FileManager.default.removeItem(at: project.root) }
        let screen = ProjectLoader.load(project: project, feed: true).screen
        guard case .thread(let shown) = screen else { throw LoadError.notAThread }
        return shown
    }

    private enum LoadError: Error { case notAThread }

    // MARK: A late answer, and content that is really drawn

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    /// A read that began with the preview off and answers after it was turned on is for the other window, and is dropped. The stale
    /// read turns the preview on itself, then answers with a screen nothing else could show; nothing here waits on a thread.
    @Test func aReadThatBeganBeforeTheFeedWasTurnedOnDoesNotReplaceTheScreen() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        let calls = Calls()
        let box = StoreBox()
        let store = ProjectStore(
            preferences: MemoryPreferences(),
            loader: { project, feed in
                guard calls.next() == 2 else { return ProjectLoader.load(project: project, feed: feed) }
                DispatchQueue.main.sync { box.store?.chatFeedOn = true }
                return ProjectLoader.Loaded(screen: .noThread, thread: nil, watch: ProjectLoader.Watch())
            })
        box.store = store
        #expect(await store.open(fixture.root))
        guard case .thread = store.screen else { throw LoadError.notAThread }
        await store.reload()
        #expect(store.chatFeedOn)
        guard case .thread = store.screen else {
            Issue.record("the answer of the read that began with the preview off replaced the screen: \(store.screen)")
            return
        }
    }

    @MainActor private final class StoreBox: @unchecked Sendable {
        weak var store: ProjectStore?
    }

    private func differs(
        _ first: some View, _ second: some View, _ what: String, width: CGFloat = 700, height: CGFloat = 160
    ) throws {
        let x = try image(first, width: width, height: height, dark: false)
        let y = try image(second, width: width, height: height, dark: false)
        #expect(x.dataProvider?.data != y.dataProvider?.data, "\(what) is not drawn")
    }

    private func row(_ kind: FeedItem.Kind) -> some View { FeedRow(item: FeedItem(id: "a", seq: 1, turn: 1, kind: kind)) }

    @Test func rowsDrawTheDetailTheySay() throws {
        try differs(
            row(.denied(tool: "Bash", input: "git push origin main")), row(.denied(tool: "Bash", input: nil)),
            "a refused call's input")
        try differs(
            row(.verify(ok: true, reason: nil, proofs: ["list-states.png"])), row(.verify(ok: true, reason: nil, proofs: [])),
            "the proof names")
        try differs(
            row(.check(result: "passed", command: "swift test", durationMs: 1_000)),
            row(.check(result: "failed", command: "swift test", durationMs: 1_000)), "a check's result")
        let started = ThreadState.derive(from: [], id: "t")
        let ended = ThreadState.derive(
            from: [
                Event(seq: 1, ts: "2026-11-02T10:00:01.000Z", turn: 0, kind: .threadCreated, data: [:]),
                Event(seq: 2, ts: "2026-11-02T10:00:02.000Z", turn: 1, kind: .turnStarted, data: [:]),
                Event(seq: 3, ts: "2026-11-02T10:00:03.000Z", turn: 1, kind: .turnEnded, data: ["result": "succeeded"]),
            ], id: "t")
        try differs(
            PhaseRow(spine: ThreadSpine.derive(state: started)),
            PhaseRow(spine: ThreadSpine.derive(state: ended, approval: .approved)),
            "the phase row", width: 800, height: 40)
    }

    @Test func theWindowDrawsTheFeedNotJustTheToolbarAndTheRail() throws {
        var snapshot = try thread(.needsYou)
        let project = Project(root: URL(fileURLWithPath: "/tmp/x"))
        let preferences = MemoryPreferences()
        preferences.chatFeed = true
        let withRows = ProjectStore(preferences: preferences, screen: .thread(snapshot), project: project)
        snapshot.feed = []
        let without = ProjectStore(preferences: preferences, screen: .thread(snapshot), project: project)
        try differs(RootView(store: withRows), RootView(store: without), "the feed", width: 1100, height: 700)
    }

    // MARK: The decision card and the messages

    private func card(_ decision: FeedDecision) -> some View {
        DecisionCard(step: .review, why: "Needs you · Review · turn 1 done", decision: decision, perform: { _ in }).padding(20)
    }

    private func cardsDiffer(_ first: FeedDecision, _ second: FeedDecision, _ what: String) throws {
        try differs(card(first), card(second), what, width: 760, height: 120)
    }

    @Test func theDecisionCardDrawsItsPrimaryButtonAndItsMenuInLightAndDark() throws {
        let primary = FeedAction(kind: .accept, title: "Accept work")
        let menu = [
            FeedAction(kind: .sendBack, title: "Send back…"), FeedAction(kind: .discard, title: "Discard…", destructive: true),
        ]
        for dark in [false, true] {
            let full = try image(card(FeedDecision(primary: primary, more: menu)), width: 760, height: 120, dark: dark)
            #expect(distinctColours(full) > 2)
            try save(full, "feed-decision-card-\(dark ? "dark" : "light")")
        }
        try cardsDiffer(FeedDecision(primary: primary, more: menu), FeedDecision(primary: nil, more: menu), "the primary button")
        try cardsDiffer(FeedDecision(primary: primary, more: menu), FeedDecision(primary: primary, more: []), "the menu")
        let disabled = FeedAction(kind: .accept, title: "Accept work", enabled: false)
        try cardsDiffer(FeedDecision(primary: primary), FeedDecision(primary: disabled), "a disabled button")
    }

    @Test func whatAnActionSaidIsDrawnAsRows() throws {
        func rows(_ error: String?, _ note: String?, _ notice: String?) -> some View {
            MessageRows(error: error, note: note, notice: notice, handoff: nil).padding(20)
        }
        let said = rows("the run did not start", "files left out", "Accepted: abc1234")
        try differs(said, rows(nil, nil, nil), "the messages", width: 640, height: 140)
        try differs(rows("broke", nil, nil), rows(nil, nil, "done"), "an error against a notice", width: 640, height: 140)
        try save(try image(said, width: 640, height: 140, dark: false), "feed-messages-light")
    }

    private func goalCard(title: String = "Add retry") -> FeedItem {
        FeedItem(id: "goal", seq: 1, turn: 0, kind: .goalCard(title: title, approval: .draft, criteria: 2, hash: nil))
    }

    private func sampleGoal() -> GoalModel {
        var goal = GoalModel.invalid(path: "/tmp/goal.md", problems: [])
        goal.rows = [
            GoalModel.Row(id: "c1", text: "Retries on 5xx", proof: "test: SyncClientTests/retries"),
            GoalModel.Row(id: "c2", text: "Never retries on 4xx", proof: "`swift test`", warning: "not in [tools] allowed"),
        ]
        return goal
    }

    @Test func theGoalCardListsTheCriteriaAndTheirProofsWhileItIsReadOnly() throws {
        let goal = sampleGoal()
        func card(_ goal: GoalModel?) -> some View { FeedRow(item: goalCard(), goal: goal).padding(20) }
        try differs(card(goal), card(nil), "the criteria", width: 640, height: 240)
        var warned = goal
        warned.rows[0].warning = "cannot be checked"
        try differs(card(goal), card(warned), "a proof's warning", width: 640, height: 240)
    }

    /// A draft goal's card is the editor: the Goal screen's blocks, in place, in place of the summary.
    /// The screen's choice, through the store, for the states a thread is in: only a draft that nothing has run is edited in the feed.
    @Test func onlyADraftThatHasNotRunIsEditedInTheFeed() async throws {
        for (approved, turn, edited) in [(false, false, true), (true, false, false), (true, true, false), (false, true, false)] {
            let fixture = try await AppFixture()
            keptFeedFixtures.append(fixture)
            try await fixture.addThread("t1", approved: approved)
            if turn { try fixture.turn("t1", 1) }
            let store = ProjectStore(preferences: MemoryPreferences())
            #expect(await store.open(fixture.root))
            guard case .thread(let shown) = store.screen else { throw LoadError.notAThread }
            #expect(store.feedEditsGoal(shown) == edited, "approved \(approved), a turn run \(turn)")
        }
        let none = ProjectStore(preferences: MemoryPreferences())
        #expect(!none.feedEditsGoal(try thread(.needsYou)), "no goal loaded")
    }

    @Test func aGoalThatDoesNotParseSaysWhyApprovalIsBlockedEvenThoughItHasNoEditor() throws {
        func card(_ problems: [String]) -> some View {
            FeedRow(item: goalCard(), goal: GoalModel.invalid(path: "/tmp/goal.md", problems: problems)).padding(20)
        }
        try differs(card(["goal.md does not parse: line 3 has no key"]), card([]), "the blockers", width: 640, height: 200)
        #expect(GoalModel.invalid(path: "/tmp/goal.md", problems: ["broken"]).editable == false)
    }

    @Test func aReadOnlyGoalCardKeepsTheRequestAndFoldsALongOne() throws {
        var goal = sampleGoal()
        goal.rows = []
        func card(_ request: String) -> some View {
            var shown = goal
            shown.request = request
            return FeedRow(item: goalCard(), goal: shown).padding(20)
        }
        try differs(card("Add retry with backoff."), card(""), "the request", width: 640, height: 260)
        let long = String(repeating: "A long request line. ", count: 60)
        try differs(card(long), card("Add retry with backoff."), "the folded long request", width: 640, height: 260)
    }

    @Test func aDraftGoalsCardIsTheEditorAndAnApprovedOnesIsTheSummary() async throws {
        let fixture = try await AppFixture()
        keptFeedFixtures.append(fixture)
        try await fixture.addThread("t1", approved: false)
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(fixture.root))
        guard case .thread(let shown) = store.screen, let goal = store.goal else { throw LoadError.notAThread }
        func card(editable: Bool) -> some View {
            FeedRow(item: goalCard(), goal: goal, store: store, editable: editable).padding(20)
        }
        try differs(card(editable: true), card(editable: false), "the editor", width: 700, height: 900)
        for dark in [false, true] {
            let drawn = try image(card(editable: true), width: 700, height: 900, dark: dark)
            try save(drawn, "feed-goal-editor-\(dark ? "dark" : "light")")
        }
    }

    /// The sheet hosts the existing Review screen: this proves it shows that screen when there is a review and says so when there is
    /// none. What the Review screen draws is its own (a scroll view, which `ImageRenderer` cannot draw), seen in the live app.
    @Test func theReviewDetailsSheetHostsTheReviewAndSaysWhenThereIsNone() async throws {
        let fixture = try await AppFixture()
        keptFeedFixtures.append(fixture)
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        let preferences = MemoryPreferences()
        preferences.chatFeed = true
        let reviewing = ProjectStore(preferences: preferences)
        #expect(await reviewing.open(fixture.root))
        guard case .thread(let shown) = reviewing.screen else { throw LoadError.notAThread }
        #expect(reviewing.review != nil, "a turn that ended awaits a review")
        let empty = ProjectStore(preferences: preferences, screen: .thread(shown), project: fixture.project)
        #expect(empty.review == nil)
        try differs(
            ReviewDetailsSheet(snapshot: shown, store: reviewing), ReviewDetailsSheet(snapshot: shown, store: empty),
            "the review in its sheet", width: 760, height: 560)
    }
}
