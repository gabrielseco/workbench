import Foundation
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptDraftCardFixtures: [AppFixture] = []

/// The draft goal card (design parity 7): what its header and footer say, the fold and the line for a goal made from a chat.
@MainActor @Suite struct DraftGoalCardTests {
    private func goal(_ configure: (inout GoalModel) -> Void = { _ in }) -> GoalModel {
        var model = GoalModel.invalid(path: ".workbench/threads/t/goal.md", problems: [])
        configure(&model)
        return model
    }

    private func step(_ name: String, skipped: Bool = false, unavailable: String? = nil) -> GoalModel.Step {
        GoalModel.Step(name: name, label: name.capitalized, skipped: skipped, known: true, unavailable: unavailable)
    }

    // MARK: Header

    @Test func theHeaderSaysWhereTheGoalStandsAndThatEveryFieldCanBeChanged() {
        let draft = DraftGoalCard.header(goal: goal(), editable: true)
        #expect(draft == .init(pill: "Needs approval", tone: .needsYou, hint: "Every field is editable"))
        let blocked = goal { $0.blockers = ["The config does not load"] }
        #expect(DraftGoalCard.header(goal: blocked, editable: true).pill == "Can't approve yet")
        #expect(DraftGoalCard.header(goal: blocked, editable: true).tone == .broken)
        let approved = goal { $0.pill = .approved }
        let done = DraftGoalCard.header(goal: approved, editable: true)
        #expect(done.pill == "Approved" && done.tone == .done)
        let stale = goal { $0.pill = .changedSinceApproval }
        #expect(DraftGoalCard.header(goal: stale, editable: true).pill == "Changed since approval")
        #expect(DraftGoalCard.header(goal: goal(), editable: false).hint == nil, "a card that cannot be edited does not say so")
    }

    // MARK: Footer

    @Test func theFooterSaysWhatApproveStarts() {
        let both = goal { $0.steps = [step("verifier"), step("judge")] }
        #expect(DraftGoalCard.footer(goal: both, base: "main") == "Starts a worktree from main with Verifier and Judge on.")
        let judgeOff = goal { $0.steps = [step("verifier"), step("judge", skipped: true)] }
        let line = DraftGoalCard.footer(goal: judgeOff, base: "main")
        #expect(line == "Starts a worktree from main with Verifier on, Judge off.")
        let judgeOnly = goal { $0.steps = [step("judge")] }
        #expect(DraftGoalCard.footer(goal: judgeOnly, base: "main") == "Starts a worktree from main with Judge on.")
        let noJudge = goal { $0.steps = [step("judge", unavailable: "no criteria")] }
        let unavailable = DraftGoalCard.footer(goal: noJudge, base: "dev")
        #expect(unavailable == "Starts a worktree from dev with Judge off.", "a step that cannot run is off")
        let bothOff = goal { $0.steps = [step("verifier", skipped: true), step("judge", skipped: true)] }
        let off = DraftGoalCard.footer(goal: bothOff, base: "main")
        #expect(off == "Starts a worktree from main with Verifier and Judge off.")
        #expect(DraftGoalCard.footer(goal: goal(), base: nil) == "Starts a worktree.", "no steps, no base: nothing more to say")
    }

    @Test func theNextCardIsTheCardsFooterOnlyForAnEditableDraft() {
        #expect(DraftGoalCard.hidesDecisionCard(editable: true))
        #expect(!DraftGoalCard.hidesDecisionCard(editable: false))
    }

    // MARK: The fold

    @Test func theFoldCountsMessagesAndIsShownOnlyForAGoalThatBeganAsAChat() async throws {
        #expect(BrainstormFold.title(count: 4) == "Brainstorm · 4 messages")
        #expect(BrainstormFold.title(count: 1) == "Brainstorm · 1 message")
        #expect(BrainstormFold.title(count: 0) == "Brainstorm · 0 messages")
        for (scenario, shown) in [(AppScenario.chatGoal, true), (.chat, true), (.draft, false), (.needsYou, false)] {
            let fixture = try await AppFixture()
            keptDraftCardFixtures.append(fixture)
            try await scenario.build(in: fixture)
            guard case .thread(let thread) = ProjectLoader.load(project: fixture.project, feed: true).screen else {
                Issue.record("no thread: \(scenario)")
                continue
            }
            #expect(BrainstormFold.shown(state: thread.state) == shown, "\(scenario)")
        }
    }

    @Test func theAgentsLineSaysNothingRunsUntilYouApprove() {
        let line = BrainstormFold.agentLine
        #expect(line.hasPrefix("I drafted a goal from this chat.") && line.contains("approve"))
    }

    // MARK: What is drawn

    private func drawn(_ view: some View) throws -> Data? {
        let framed = view.frame(width: 700, height: 200).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        return try #require(renderer.cgImage).dataProvider?.data as Data?
    }

    /// The card with a real goal read from a fixture, in both appearances. `ImageRenderer` draws native controls (the text boxes) as placeholders,
    /// so this is for the layout: the header, the blocks and the footer. Set `WORKBENCH_RENDER_DIR` to keep the images.
    @Test(arguments: [AppScenario.draft, .goalWarning, .chatGoal])
    func theCardIsDrawnWithItsHeaderBlocksAndFooter(_ scenario: AppScenario) async throws {
        let fixture = try await AppFixture()
        keptDraftCardFixtures.append(fixture)
        try await scenario.build(in: fixture)
        guard case .thread(let thread) = ProjectLoader.load(project: fixture.project, feed: true).screen else {
            Issue.record("no thread")
            return
        }
        let model = await GoalModel.load(project: fixture.project, thread: thread.id) { _, _ in true }
        let store = ProjectStore(preferences: MemoryPreferences(), project: fixture.project)
        let decision = store.feedDecision(for: thread)
        let card = DraftGoalCardView(goal: model, store: store, base: thread.base, decision: decision) { _ in }
        let directory = ProcessInfo.processInfo.environment["WORKBENCH_RENDER_DIR"]
        var seen: [Data?] = []
        for dark in [false, true] {
            let framed = card.frame(width: 680).padding(20).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.height > 300, "the header, the blocks and the footer take room: \(image.height)")
            seen.append(image.dataProvider?.data as Data?)
            if let directory {
                let name = "draft-card-\(scenario.rawValue)-\(dark ? "dark" : "light").png"
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        #expect(seen[0] != seen[1], "light and dark differ")
    }

    @Test func theFoldAndTheAgentsLineAreDrawn() async throws {
        let blank = try drawn(Color.clear)
        let fixture = try await AppFixture()
        keptDraftCardFixtures.append(fixture)
        try await AppScenario.chatGoal.build(in: fixture)
        guard case .thread(let thread) = ProjectLoader.load(project: fixture.project, feed: true).screen else {
            Issue.record("no thread")
            return
        }
        let messages = thread.state.chat?.messages ?? []
        #expect(!messages.isEmpty)
        #expect(try drawn(BrainstormFoldView(messages: messages)) != blank)
        #expect(try drawn(AgentLineView(text: BrainstormFold.agentLine)) != blank)
    }
}
