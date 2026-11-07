import SwiftUI

extension View {
    /// Every modal of the window, in the order they stack: a later one opens over an earlier one (the discard over the review). They stand
    /// at the window, not in the screen that asked, so the rail and the toolbar are behind them too. Each is one `.modal` (`Modal.swift`).
    func appModals(_ store: ProjectStore) -> some View {
        // A modal asked for from the feed is not left behind when the window moves to another screen (⌘N, the Tasks page).
        onChange(of: store.showsFeed) { if !store.showsFeed { store.modals = ModalState() } }
            .onChange(of: store.newThread) { store.modals = ModalState() }
            .modal("Agents", isPresented: Bindable(store).showingAgents, size: .medium) { AgentsCard(store: store) }
            .modal("Projects", isPresented: Bindable(store).pickingProject, size: .small, placement: .topLeading) {
                ProjectPickerCard(store: store)
            }
            .modal(
                "Review", isPresented: closing(store.reviewOverFeed) { store.modals.reviewingDetails = false }, size: .large,
                closesOnOutsideClick: false
            ) {
                if case .thread(let snapshot) = store.screen { ReviewDetailsBody(snapshot: snapshot, store: store) }
            }
            .modal(
                "Run settings", isPresented: closing(store.runSettingsOverFeed) { store.setRunSettings(false) }, size: .small,
                closesOnOutsideClick: false
            ) {
                if case .thread(let snapshot) = store.screen { RunSettingsBody(snapshot: snapshot, store: store) }
            }
            .modal(
                "Diff", isPresented: closing(store.diffOverFeed != nil) { store.modals.diffPath = nil }, size: .large,
                closesOnOutsideClick: false
            ) {
                if let path = store.diffOverFeed { DiffBody(store: store, path: path) }
            }
            .modal(
                store.previewShown?.title ?? "Screenshot",
                isPresented: closing(store.previewShown != nil) { store.modals.preview = nil }, size: .fitting,
                closesOnOutsideClick: false,
                accessory: { if let preview = store.previewShown { ScreenshotPreviewControls(model: preview) } },
                content: { if let preview = store.previewShown { ScreenshotPreviewBody(model: preview) } }
            )
            .modal(
                "Discard", isPresented: closing(store.discardOverFeed) { store.cancelDiscard() }, size: .medium,
                closesOnOutsideClick: false
            ) {
                DiscardBody(store: store)
            }
            .modal(
                "PR review", isPresented: closing(store.prReviewOverFeed) { store.closePRReview() }, size: .large,
                closesOnOutsideClick: false
            ) {
                PRReviewBody(store: store)
            }
            .modal(
                mergeTitle(store), isPresented: closing(store.mergeOverFeed) { store.modals.confirmingMerge = false },
                size: .small,
                closesOnOutsideClick: false
            ) {
                MergeBody(store: store)
            }
    }

    /// A flag the store derives, as a binding whose only write is to close it.
    private func closing(_ shown: Bool, close: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { shown }, set: { if !$0 { close() } })
    }

    private func mergeTitle(_ store: ProjectStore) -> String {
        if case .thread(let snapshot) = store.screen, let pr = snapshot.state.pullRequest { return "Merge PR #\(pr.number)" }
        return "Merge"
    }
}

/// The modals a launch can open (`LaunchOptions.opens`), by the name `WORKBENCH_APP_OPEN` gives.
enum LaunchModal: String, Equatable {
    case review, diff, discard
    case prReview = "pr-review"
    case merge
}

extension ProjectStore {
    /// Opens that modal as its own button or menu would, on the thread on screen.
    func show(_ modal: LaunchModal) async {
        switch modal {
        case .review: modals.reviewingDetails = true
        case .diff:
            modals.reviewingDetails = true
            modals.diffPath = review?.files.first?.path
        case .discard: await prepareDiscard()
        case .prReview: await showPRReview()
        case .merge: modals.confirmingMerge = true
        }
    }
}
