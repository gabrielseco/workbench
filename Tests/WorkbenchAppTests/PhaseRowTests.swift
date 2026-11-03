import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptPhaseFixtures: [AppFixture] = []

/// The phase row (design parity 3): its dots, its steps and what each says to VoiceOver.
@MainActor @Suite struct PhaseRowTests {
    private func snapshot(_ scenario: AppScenario) async throws -> ThreadSnapshot {
        let fixture = try await AppFixture()
        keptPhaseFixtures.append(fixture)
        try await scenario.build(in: fixture)
        guard case .thread(let shown) = ProjectLoader.load(project: fixture.project, feed: true).screen else {
            throw Failure.notAThread
        }
        return shown
    }

    @Test func eachMarkHasItsDotAndItsLabelStyle() {
        #expect(PhaseDot.of(.done) == PhaseDot(filled: true, label: .secondary))
        for mark in [SpineMark.current, .needsYou, .failed] {
            #expect(PhaseDot.of(mark) == PhaseDot(filled: true, label: .primary), "\(mark)")
        }
        #expect(PhaseDot.of(.pending) == PhaseDot(filled: false, label: .tertiary))
    }

    @Test func aChatIsOnTheChatStepAndNoOtherAndShowsTheRow() async throws {
        for scenario in [AppScenario.chat, .chatReplying] {
            let shown = try await snapshot(scenario)
            let steps = PhaseRow.steps(for: shown)
            let titles = ["Chat", "Goal", "Run", "Review", "Accept", "Ship", "PR review", "Clean"]
            #expect(steps.map(\.title) == titles, "\(scenario)")
            #expect(steps.first == PhaseStep(title: "Chat", mark: .current, sublabel: "talking it through"))
            #expect(steps.dropFirst().allSatisfy { $0.mark == .pending }, "a chat has no goal yet, so it is on no step")
        }
    }

    @Test func aChatThatBecameAGoalHasChatDoneAndTheSpineAsItIs() async throws {
        let shown = try await snapshot(.chatGoal)
        let steps = PhaseRow.steps(for: shown)
        #expect(steps.first == PhaseStep(title: "Chat", mark: .done, sublabel: "became the goal"))
        #expect(Array(steps.dropFirst()).map(\.mark) == shown.spine.entries.map(\.mark))
        #expect(steps.dropFirst().first?.title == "Goal")
    }

    @Test func aThreadThatBeganAsAGoalHasNoChatStepAndKeepsAccept() async throws {
        for scenario in [AppScenario.draft, .running, .needsYou] {
            let shown = try await snapshot(scenario)
            let steps = PhaseRow.steps(for: shown)
            #expect(steps.map(\.title) == ["Goal", "Run", "Review", "Accept", "Ship", "PR review", "Clean"], "\(scenario)")
            #expect(steps.map(\.mark) == shown.spine.entries.map(\.mark), "the spine's marks, unchanged")
        }
    }

    @Test func eachStepSaysItsTitleMarkAndSublabelToVoiceOver() async throws {
        let steps = PhaseRow.steps(for: try await snapshot(.chatGoal))
        #expect(steps.first?.spoken == "Chat, done, became the goal")
        let spine = try await snapshot(.needsYou).spine
        for (step, entry) in zip(PhaseRow.steps(for: try await snapshot(.needsYou)), spine.entries) {
            #expect(step.spoken == "\(entry.step.title), \(entry.mark.rawValue), \(entry.sublabel)")
        }
    }

    private enum Failure: Error { case notAThread }
}
