import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// When the modals that belong to the feed are up. They stand at the window (`AppModals.swift`), so the store, not the screen that asked,
/// says whether one is shown, and a screen that is not the feed never shows the feed's.
@MainActor @Suite struct AppModalsTests {
    private func feedStore() async throws -> (ProjectStore, AppFixture) {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        try fixture.turn("t1", 1)
        let store = ProjectStore(preferences: MemoryPreferences())
        #expect(await store.open(fixture.root))
        return (store, fixture)
    }

    @Test func theRunSettingsOpenOverTheFeedOnlyWhenChosenAndTheWindowIsTooNarrowForThemBeside() async throws {
        let (store, fixture) = try await feedStore()
        withExtendedLifetime(fixture) {}
        #expect(store.showsFeed)
        store.runSettingsFits = false
        #expect(!store.runSettingsOverFeed, "the default, not chosen: a narrow window shows nothing")
        store.setRunSettings(true)
        #expect(store.runSettingsOverFeed, "chosen in a narrow window: over the feed")
        store.runSettingsFits = true
        #expect(!store.runSettingsOverFeed, "room beside the feed: not over it")
        store.runSettingsFits = false
        store.setRunSettings(false)
        #expect(!store.runSettingsOverFeed, "closed")
    }

    @Test func theFeedsModalsAreNotUpOverAnotherScreen() async throws {
        let (store, fixture) = try await feedStore()
        withExtendedLifetime(fixture) {}
        store.runSettingsFits = false
        store.setRunSettings(true)
        #expect(store.runSettingsOverFeed)
        store.newThread = true
        #expect(!store.showsFeed && !store.runSettingsOverFeed, "the new-goal screen is not the feed")
        store.newThread = false
        store.mode = .tasks
        #expect(!store.runSettingsOverFeed, "nor is the Tasks screen")
        #expect(!ProjectStore(preferences: MemoryPreferences()).showsFeed, "no project, no feed")
    }

    @Test func openingAProjectClosesTheReviewTheMergeQuestionAndTheDiff() async throws {
        let (store, fixture) = try await feedStore()
        store.modals = ModalState(reviewingDetails: true, confirmingMerge: true, diffPath: "Sources/A.swift")
        #expect(await store.open(fixture.root))
        let modals = store.modals
        #expect(!modals.reviewingDetails && !modals.confirmingMerge && modals.diffPath == nil)
    }

    @Test func theFeedsModalsAreNotUpOnceTheWindowMovesToAnotherScreen() async throws {
        let (store, fixture) = try await feedStore()
        withExtendedLifetime(fixture) {}
        store.modals = ModalState(reviewingDetails: true, confirmingMerge: true, diffPath: "Sources/A.swift")
        store.prReviewShown = PRReviewShown(pr: 7, round: 1, verdict: .clean, failure: nil, findings: "all good")
        #expect(store.reviewOverFeed && store.mergeOverFeed && store.diffOverFeed == "Sources/A.swift" && store.prReviewOverFeed)
        store.newThread = true
        #expect(!store.reviewOverFeed && !store.mergeOverFeed && store.diffOverFeed == nil, "⌘N: the review is not over New goal")
        #expect(!store.prReviewOverFeed && !store.discardOverFeed)
    }
}
