import AppKit
import SwiftUI

/// One screenshot, or a set to page through, shown large in a modal sized to it (`AppModals.swift`). It is shown at its own point size (a
/// Retina screenshot pixel for pixel), shrunk to fit only when it is bigger, never stretched; when shrunk, a click or the toggle shows it
/// actual size in a scroll view. The model holds what the title, the controls and the picture all read, since they are three views.
@MainActor @Observable final class ScreenshotPreviewModel {
    struct Shot: Equatable {
        var url: URL
        var caption: String
    }

    let shots: [Shot]
    private(set) var index: Int
    private let fixedTitle: String?
    /// What is said beside the controls, for a screenshot that is not sent yet.
    let note: String?
    /// The staged screenshot this shows: once it is no longer staged (the composer moved to another thread, or it was sent) nothing is.
    private let staged: (staging: AttachmentStaging, id: UUID)?
    /// Whether it belongs to the thread feed (the verifier's screenshots), so it is not left over another screen.
    let needsFeed: Bool
    private(set) var decoded: StagedScreenshotImage?
    private(set) var missing = false
    var actualSize = false

    private init(
        shots: [Shot], index: Int, title: String?, note: String?, staged: (staging: AttachmentStaging, id: UUID)?, needsFeed: Bool
    ) {
        (self.shots, self.index, fixedTitle) = (shots, index, title)
        (self.note, self.staged, self.needsFeed) = (note, staged, needsFeed)
    }

    /// A screenshot staged on a card, numbered among its siblings.
    static func staged(_ staging: AttachmentStaging, _ item: AttachmentStaging.Item, number: Int) -> ScreenshotPreviewModel {
        let count = staging.items.count
        return ScreenshotPreviewModel(
            shots: [Shot(url: item.url, caption: "Screenshot")], index: 0,
            title: count > 1 ? "Screenshot \(number) of \(count)" : "Screenshot",
            note: "Not sent yet. Closing keeps it attached.", staged: (staging, item.id), needsFeed: false)
    }

    /// The verifier's screenshots, opened at one of them.
    static func proof(_ shots: [ProofShot], at index: Int) -> ScreenshotPreviewModel {
        ScreenshotPreviewModel(
            shots: shots.map { Shot(url: $0.url, caption: $0.caption) }, index: min(max(index, 0), max(shots.count - 1, 0)),
            title: nil, note: nil, staged: nil, needsFeed: true)
    }

    var shot: Shot { shots[index] }
    var title: String {
        fixedTitle ?? (shots.count > 1 ? "\(shot.caption) · \(index + 1) of \(shots.count)" : shot.caption)
    }
    var isPaged: Bool { shots.count > 1 }
    var isStale: Bool { staged.map { staged in !staged.staging.items.contains { $0.id == staged.id } } ?? false }

    func go(_ to: Int) {
        index = min(max(to, 0), shots.count - 1)
        (decoded, missing, actualSize) = (nil, false, false)
    }

    /// Decodes the shot on screen. Paging cancels the task, but the detached decode still finishes: a superseded one must not replace
    /// the current picture.
    func load() async {
        let url = shot.url
        let loaded = await Task.detached(priority: .userInitiated) { StagedScreenshotImage.decode(url) }.value
        guard !Task.isCancelled, url == shot.url else { return }
        (decoded, missing) = (loaded, loaded == nil)
    }

    /// The room the picture can take: the window's, less a margin round the card and the card's own padding and header.
    static func room(in window: CGSize) -> CGSize {
        CGSize(
            width: window.width - 2 * Space.xl - 2 * Space.l,
            height: window.height - 2 * Space.xl - 2 * Space.l - Self.header)
    }

    /// The header row and the gap under it, which the modal adds to the picture's height.
    private static let header: CGFloat = 40
    static let smallest = CGSize(width: 480, height: 320)

    func fits(scale: CGFloat, room: CGSize) -> Bool {
        guard let decoded else { return true }
        let size = decoded.points(at: scale)
        return size.width <= room.width && size.height <= room.height
    }

    /// The picture's area: its own size within `room`, no smaller than `smallest`; a size to wait in until it is decoded.
    func area(scale: CGFloat, room: CGSize) -> CGSize {
        guard let decoded else { return Self.smallest }
        let size = decoded.points(at: scale)
        return CGSize(
            width: max(Self.smallest.width, min(size.width, room.width)),
            height: max(Self.smallest.height, min(size.height, room.height)))
    }
}

/// What opens a preview: set by the window, so a thumbnail anywhere asks it without holding the store.
private struct OpenScreenshotPreviewKey: EnvironmentKey {
    static let defaultValue: @MainActor (ScreenshotPreviewModel) -> Void = { _ in }
}

extension EnvironmentValues {
    var openScreenshotPreview: @MainActor (ScreenshotPreviewModel) -> Void {
        get { self[OpenScreenshotPreviewKey.self] }
        set { self[OpenScreenshotPreviewKey.self] = newValue }
    }
}

/// Beside the modal's close button: the note, previous and next (and the arrow keys), and fit or actual size.
struct ScreenshotPreviewControls: View {
    var model: ScreenshotPreviewModel
    @Environment(\.displayScale) private var displayScale
    @Environment(\.modalRoom) private var window

    var body: some View {
        HStack(spacing: Space.m) {
            if let note = model.note { Text(note).role(.caption) }
            if model.isPaged {
                IconButton.raised("chevron.left", "Previous screenshot", help: "Previous (←)") { model.go(model.index - 1) }
                    .keyboardShortcut(.leftArrow, modifiers: []).disabled(model.index == 0)
                IconButton.raised("chevron.right", "Next screenshot", help: "Next (→)") { model.go(model.index + 1) }
                    .keyboardShortcut(.rightArrow, modifiers: []).disabled(model.index == model.shots.count - 1)
            }
            if model.decoded != nil, !model.fits(scale: displayScale, room: ScreenshotPreviewModel.room(in: window)) {
                let symbol = model.actualSize ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                IconButton.raised(symbol, model.actualSize ? "Fit to window" : "Actual size") { model.actualSize.toggle() }
            }
        }
    }
}

/// The picture, in an area sized to it.
struct ScreenshotPreviewBody: View {
    var model: ScreenshotPreviewModel
    @Environment(\.displayScale) private var displayScale
    @Environment(\.modalRoom) private var window

    var body: some View {
        let room = ScreenshotPreviewModel.room(in: window)
        let area = model.area(scale: displayScale, room: room)
        picture(fits: model.fits(scale: displayScale, room: room))
            .frame(width: area.width, height: area.height)
            .task(id: model.shot.url) { await model.load() }
    }

    @ViewBuilder private func picture(fits: Bool) -> some View {
        if let decoded = model.decoded {
            let size = decoded.points(at: displayScale)
            let shown = Image(decorative: decoded.image, scale: CGFloat(decoded.image.width) / size.width)
            if model.actualSize && !fits {
                ScrollView([.horizontal, .vertical]) { shown.onTapGesture { model.actualSize = false } }
                    .thumbnail(outlined: true)
            } else {
                shown.resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: size.width, maxHeight: size.height).thumbnail(outlined: true)
                    .onTapGesture { if !fits { model.actualSize = true } }
            }
        } else {
            Rectangle().fill(Theme.canvas).thumbnail(outlined: true)
                .overlay {
                    if model.missing {
                        Image(systemName: "photo").foregroundStyle(Theme.fg3)
                    } else {
                        Spinner()
                    }
                }
        }
    }
}
