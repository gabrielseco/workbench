import AppKit
import SwiftUI
import WorkbenchCore

/// The staged screenshots as small thumbnails, each with a remove button: the new-thread screen's and the chat composer's. Clicking
/// one shows it large in a modal; closing that leaves it staged.
struct StagedThumbnails: View {
    /// A staged screenshot's thumbnail is this square.
    static let side: CGFloat = 44
    var staging: AttachmentStaging
    @Environment(\.openScreenshotPreview) private var openPreview

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(Array(staging.items.enumerated()), id: \.element.id) { index, item in
                ZStack(alignment: .topTrailing) {
                    Button { openPreview(.staged(staging, item, number: index + 1)) } label: {
                        Group {
                            if let image = item.thumbnail { Image(nsImage: image).resizable().scaledToFill() } else {
                                Theme.grey.opacity(0.3)
                            }
                        }
                        .frame(width: StagedThumbnails.side, height: StagedThumbnails.side).thumbnail().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Preview screenshot \(index + 1)").help("Preview screenshot")
                    IconButton.badge("Remove screenshot \(index + 1)", help: "Remove screenshot") { staging.remove(item) }
                        .padding(Space.xxs)
                }
            }
            Spacer()
        }
    }
}

/// A staged screenshot decoded for the preview, with the pixel size of the file it came from.
struct StagedScreenshotImage: @unchecked Sendable {
    var image: CGImage
    var pixels: CGSize

    /// Longest side decoded: a 5K screenshot whole, while a bigger image (Core allows 40 million pixels) costs a bounded bitmap.
    static let maxPixels = 6144

    /// Its size in points on a display of `scale`: a screenshot taken on a Retina screen is shown at the size it was on that screen.
    func points(at scale: CGFloat) -> CGSize {
        let scale = max(scale, 1)
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    nonisolated static func decode(_ url: URL) -> StagedScreenshotImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // The transform may have turned the picture a quarter: the size shown is the decoded one's shape at the file's scale.
        let ratio = CGFloat(max(width, height)) / CGFloat(max(image.width, image.height))
        let pixels = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
        return StagedScreenshotImage(image: image, pixels: pixels)
    }
}

/// The `+` that opens the file chooser for screenshots.
struct AddScreenshotsButton: View {
    var staging: AttachmentStaging
    var disabled = false
    var size: ButtonSize = .small

    var body: some View {
        IconButton.raised("plus", "Add screenshots…", help: "Add screenshots", size: size, action: choose).disabled(disabled)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { Task { await staging.add(files: panel.urls) } }
    }
}

extension View {
    /// Image files dropped on this view are staged, while `allowed` says so.
    func screenshotDrop(_ staging: AttachmentStaging, allowed: Bool) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            guard allowed else { return false }
            Task { await staging.add(files: urls) }
            return true
        }
    }

    /// ⌘V while this view is up takes a screenshot off the clipboard when `allowed` says so; text on the clipboard still goes to the
    /// text box. `staging` is asked at the paste, not when the view appeared: a composer kept while the window moves to another thread
    /// stages into that thread's screenshots.
    func pastesScreenshots(
        _ staging: @escaping @MainActor () -> AttachmentStaging, allowed: @escaping @MainActor () -> Bool
    ) -> some View {
        modifier(PastesScreenshots(staging: staging, allowed: allowed))
    }
}

private struct PastesScreenshots: ViewModifier {
    var staging: @MainActor () -> AttachmentStaging
    var allowed: @MainActor () -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { watch() }
            .onDisappear {
                monitor.map(NSEvent.removeMonitor)
                monitor = nil
            }
    }

    private func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [staging, allowed] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "v", MainActor.assumeIsolated({ allowed() }),
                AttachmentStaging.wantsImages(.general)
            else { return event }
            Task { @MainActor in await staging().add(from: .general) }
            return nil
        }
    }
}
