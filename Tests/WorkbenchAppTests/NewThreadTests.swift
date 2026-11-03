import Foundation
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptNewThreadFixtures: [AppFixture] = []

/// The new-thread screen (design parity 6): its rules, how it opens and closes, and what its three buttons do.
@MainActor @Suite struct NewThreadTests {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    private func store(
        seen: Seen = Seen(), refuse: Error? = nil
    ) async throws -> (ProjectStore, AppFixture) {
        let fixture = try await AppFixture()
        keptNewThreadFixtures.append(fixture)
        try await fixture.addThread("t1")
        let preferences = MemoryPreferences(projectPath: nil)
        let actions = GoalActions(
            draftGoal: { _, name, request, attachments, _ in
                seen.add("draft \(name)|\(request)|\(attachments.count)")
                if let refuse { throw refuse }
                return GoalDraftResult(id: "g-\(name)", provider: .claude)
            },
            chat: { _, target, message, _ in
                seen.add("chat \(target)|\(message)")
                if let refuse { throw refuse }
                return ChatResult(id: "g-2026-11-03-x", reply: "ok", end: "ok", provider: .claude)
            },
            quickGoal: { _, name, request, attachments in
                seen.add("quick \(name)|\(request)|\(attachments.count)")
                return "g-\(name)"
            },
            enableGoalAgent: { _, provider in seen.add("enable \(provider.rawValue)") })
        let store = ProjectStore(preferences: preferences, actions: actions)
        #expect(await store.open(fixture.root))
        return (store, fixture)
    }

    // MARK: Rules

    @Test func sendNeedsTextNoScreenshotsAndNothingGoing() {
        var state = NewThreadState(text: "Fix the header")
        #expect(state.canSend && state.canDoItNow && state.canWriteAsGoal)
        state.screenshots = 1
        #expect(!state.canSend && state.canDoItNow, "a chat takes no screenshots; Do it now does")
        #expect(state.sendHelp == "A chat takes no screenshots: use Draft the goal.")
        state.screenshots = 0
        state.pending = 1
        #expect(!state.canSend && !state.canDoItNow, "an image still being read is not left out")
        state.pending = 0
        state.busy = true
        #expect(!state.canSend && !state.canDoItNow && !state.canWriteAsGoal)
        #expect(!NewThreadState(text: "  \n ").canSend && !NewThreadState(text: "").canDoItNow)
    }

    @Test func returnSendsCommandReturnIsDoItNowAndShiftOrOptionReturnAddsALine() {
        #expect(NewThreadState.key(shift: false, option: false, command: false) == .send)
        #expect(NewThreadState.key(shift: false, option: false, command: true) == .doItNow)
        #expect(NewThreadState.key(shift: true, option: false, command: false) == .newline)
        #expect(NewThreadState.key(shift: false, option: true, command: false) == .newline)
    }

    // MARK: Opening and closing

    @Test func everyNewGoalButtonOpensTheScreen() async throws {
        let (store, _) = try await store()
        store.beginNewGoal()
        #expect(store.newThread)
    }

    @Test func choosingARowEscapeAndMakingAThreadAllCloseIt() async throws {
        let (store, _) = try await store()
        store.beginNewGoal()
        await store.select(thread: "t1")
        #expect(!store.newThread)
        store.beginNewGoal()
        store.selectTask("nightly-lint")
        #expect(!store.newThread)
        store.beginNewGoal()
        store.showTasks()
        #expect(!store.newThread)
        store.beginNewGoal()
        store.closeNewThread()
        #expect(!store.newThread)
    }

    @Test func theRailShowsANewThreadRowFirstAndSelectedWhileItIsOpen() async throws {
        let (store, _) = try await store()
        let listing = store.threads.listing
        #expect(RailModel.derive(listing: listing, tasks: nil).composing == nil)
        let model = RailModel.derive(listing: listing, tasks: nil, composing: true)
        #expect(model.composing?.title == "New thread" && model.composing?.line == "Type to start · free")
        #expect(model.composing?.id != model.threads.first?.id)
    }

    @Test func theFooterAndTheToolbarSayNothingIsRunningWhileItIsOpen() async throws {
        let fixture = try await AppFixture()
        keptNewThreadFixtures.append(fixture)
        try await fixture.addThread("t1", approved: true)
        guard case .thread(let shown) = ProjectLoader.load(project: fixture.project).screen else {
            Issue.record("no thread")
            return
        }
        #expect(FooterBar.limitText(.thread(shown), mode: .thread, composing: false) != nil)
        #expect(FooterBar.limitText(.thread(shown), mode: .thread, composing: true) == nil)
    }

    // MARK: The three buttons

    @Test func sendStartsAChatFromTheTextAndClosesTheScreenAndKeepsTheTextOnARefusal() async throws {
        let seen = Seen()
        let (store, _) = try await store(seen: seen)
        store.beginNewGoal()
        store.newThreadText = "Could uploads retry?"
        #expect(await store.sendNewThread())
        #expect(seen.all == ["chat newThread(name: \"could-uploads-retry\")|Could uploads retry?"])
        #expect(store.newThreadText.isEmpty && !store.newThread)

        let (refusing, _) = try await self.store(refuse: ChatRefusal.activeThread("t1"))
        refusing.beginNewGoal()
        refusing.newThreadText = "Another idea"
        #expect(await refusing.sendNewThread() == false)
        #expect(refusing.newThreadText == "Another idea" && refusing.newThread, "the text and the screen stay")
        #expect(refusing.actionError == "\(ChatRefusal.activeThread("t1"))")
    }

    @Test func doItNowDraftsFromTheWordsAndTheScreenshotsAndWriteItAsTheGoalIsAQuickGoal() async throws {
        let seen = Seen()
        let (store, _) = try await store(seen: seen)
        store.beginNewGoal()
        store.newThreadText = "  Fix the header\n"
        let shot = URL(fileURLWithPath: "/staged/1.png")
        #expect(await store.draftNewThread(attachments: [shot]))
        #expect(seen.all == ["draft fix-the-header|Fix the header|1"])
        #expect(store.newThreadText.isEmpty && !store.newThread)

        store.beginNewGoal()
        store.newThreadText = "Do the thing"
        #expect(await store.quickNewThread(attachments: []))
        #expect(seen.all.last == "quick do-the-thing|Do the thing|0")
    }

    @Test func nothingIsAskedOfAnyoneForBlankText() async throws {
        let seen = Seen()
        let (store, _) = try await store(seen: seen)
        store.beginNewGoal()
        store.newThreadText = " \n "
        let sent = await store.sendNewThread()
        let drafted = await store.draftNewThread(attachments: [])
        let quick = await store.quickNewThread(attachments: [])
        #expect(!sent && !drafted && !quick)
        #expect(seen.all.isEmpty && store.newThread)
    }

    @Test func aProjectWithNoGoalAgentCanNameOneAndDraft() async throws {
        let seen = Seen()
        let (store, _) = try await store(seen: seen, refuse: GoalDraftRefusal.noGoalAgent)
        store.beginNewGoal()
        store.newThreadText = "Fix it"
        #expect(await store.draftNewThread(attachments: []) == false)
        #expect(store.goalAgentOff && store.newThread && store.newThreadText == "Fix it")
        #expect(seen.all == ["draft fix-it|Fix it|0"])
        _ = await store.draftNewThread(naming: .codex, attachments: [])
        #expect(seen.all == ["draft fix-it|Fix it|0", "enable codex", "draft fix-it|Fix it|0"], "it names the agent, then drafts")
    }

    // MARK: What is drawn

    private func drawn(_ view: some View, height: CGFloat = 200) throws -> Data? {
        let framed = view.frame(width: 700, height: height).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        return try #require(renderer.cgImage).dataProvider?.data as Data?
    }

    @Test func eachPartOfTheScreenIsDrawnOnItsOwn() throws {
        let blank = try drawn(Color.clear)
        #expect(try drawn(NewThreadHeading()) != blank)
        #expect(try drawn(NewThreadCaption()) != blank)
    }

    @Test func theBoxGrowsWithTheLinesATextWrapsIntoNotOnlyItsNewlines() {
        let long = String(repeating: "a long line that wraps ", count: 20)
        #expect(NewThreadState.lineCount("", width: 300) == 1 && NewThreadState.lineCount("one line", width: 300) == 1)
        #expect(NewThreadState.lineCount("a\nb\nc", width: 300) == 3)
        #expect(NewThreadState.lineCount("a\n", width: 300) == 2, "a trailing newline is a line to type on")
        #expect(NewThreadState.lineCount(long, width: 300) > 5, "a paragraph wraps")
        #expect(NewThreadState.lineCount(long, width: 600) < NewThreadState.lineCount(long, width: 300), "a wider box wraps less")
        #expect(NewThreadState.editorHeight(lines: 1) == NewThreadState.editorHeight(lines: 2), "roomy when empty")
        #expect(NewThreadState.editorHeight(lines: 5) > NewThreadState.editorHeight(lines: 3))
        #expect(NewThreadState.editorHeight(lines: 50) == NewThreadState.editorHeight(lines: 8), "it stops at eight and scrolls")
    }

    @Test func whatWasTypedInOneProjectIsNotOfferedToAnother() async throws {
        let (store, _) = try await store()
        store.beginNewGoal()
        store.newThreadText = "A request for project A"
        let other = try await AppFixture()
        keptNewThreadFixtures.append(other)
        try await other.addThread("o1")
        #expect(await store.open(other.root))
        #expect(store.newThreadText.isEmpty && !store.newThread)
    }

    @Test func theNewThreadRowOfThePhaseRowHasChatCurrentAndTheRestPending() {
        let steps = PhaseRow.newThreadSteps
        #expect(steps.map(\.title) == ["Chat", "Goal", "Run", "Review", "Accept", "Ship", "PR review", "Clean"])
        #expect(steps.first?.mark == .current && steps.dropFirst().allSatisfy { $0.mark == .pending })
    }
}
