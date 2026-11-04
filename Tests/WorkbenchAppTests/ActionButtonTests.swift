import SwiftUI
import Testing

@testable import WorkbenchApp

/// The action button takes its wording, enabled state and hover help from the action and its look from a kind and a size.
@MainActor @Suite struct ActionButtonTests {
    private func described(_ button: ActionButton) -> String { String(describing: button.body) }

    @Test func theLookIsTheKindAndSizeItIsGiven() {
        let action = FeedAction(kind: .ship, title: "Ship", help: "Pushes it")
        let primary = described(ActionButton(action: action, kind: .primary, perform: { _ in }))
        let plain = described(ActionButton(action: action, size: .compact, perform: { _ in }))
        #expect(primary.contains("ButtonKind.primary") && primary.contains("ButtonSize.regular"))
        #expect(plain.contains("ButtonKind.plain") && plain.contains("ButtonSize.compact"))
    }

    @Test func theLabelCanBeOverriddenAndHelpFallsBackToTheTitle() {
        let plain = FeedAction(kind: .accept, title: "Accept work")
        let helped = FeedAction(kind: .accept, title: "Accept work", help: "Commits it")
        #expect(ActionButton(action: plain, perform: { _ in }).label == "Accept work")
        #expect(ActionButton(action: plain, title: "Accept", perform: { _ in }).label == "Accept")
        #expect(ActionButton(action: plain, perform: { _ in }).hover == "Accept work")
        #expect(ActionButton(action: helped, perform: { _ in }).hover == "Commits it")
    }

    @Test func thePerformClosureGetsTheActionItWasBuiltWith() {
        var got: [FeedAction.Kind] = []
        let action = FeedAction(kind: .openPR, title: "Open PR")
        ActionButton(action: action, perform: { got.append($0.kind) }).perform(action)
        #expect(got == [.openPR])
    }
}
