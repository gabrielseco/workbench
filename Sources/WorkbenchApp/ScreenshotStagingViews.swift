import AppKit
import SwiftUI
import WorkbenchCore

/// The staged screenshots as small thumbnails, each with a remove button: the new-thread screen's and the chat composer's. Clicking
/// one shows it large; closing that leaves it staged.
struct StagedThumbnails: View {
    var staging: AttachmentStaging
    @State private var previewing: AttachmentStaging.Item.ID?

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(Array(staging.items.enumerated()), id: \.element.id) { index, item in
                ZStack(alignment: .topTrailing) {
                    Button { previewing = item.id } label: {
                        Group {
                            if let image = item.thumbnail { Image(nsImage: image).resizable().scaledToFill() } else {
                                Theme.grey.opacity(0.3)
                            }
                        }
                        .frame(width: 44, height: 44).thumbnail().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Preview screenshot \(index + 1)").help("Preview screenshot")
                    Button { staging.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Remove screenshot \(index + 1)").padding(Space.xxs)
                }
            }
            Spacer()
        }
        .sheet(item: Binding(get: { preview }, set: { previewing = $0?.item.id })) { shown in
            StagedScreenshotPreview(item: shown.item, number: shown.number, count: staging.items.count)
        }
        // A screenshot that is no longer staged (the composer moved to another thread, or it was sent) is not previewed.
        .onChange(of: staging.items.map(\.id)) { _, ids in
            if let previewing, !ids.contains(previewing) { self.previewing = nil }
        }
    }

    private var preview: Preview? {
        guard let previewing, let index = staging.items.firstIndex(where: { $0.id == previewing }) else { return nil }
        return Preview(item: staging.items[index], number: index + 1)
    }

    private struct Preview: Identifiable {
        var item: AttachmentStaging.Item
        var number: Int
        var id: UUID { item.id }
    }
}

/// One staged screenshot in a sheet sized to it, up to most of the screen. It is shown at its own point size (a Retina screenshot
/// pixel for pixel), shrunk to fit only when it is bigger, never stretched; when shrunk, a click or the toggle shows it actual size in a
/// scroll view. The × or Escape goes back to the message with the screenshot still attached.
struct StagedScreenshotPreview: View {
    var item: AttachmentStaging.Item
    var number: Int
    var count: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var decoded: StagedScreenshotImage?
    @State private var missing = false
    @State private var actualSize = false

    /// The header's height and the gap under it, which the sheet adds to the image's.
    private static let header: CGFloat = 40
    private static let smallest = CGSize(width: 520, height: 360)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Text(count > 1 ? "Screenshot \(number) of \(count)" : "Screenshot").textStyle(.heading)
                Text("Not sent yet").role(.caption)
                Spacer()
                if decoded != nil, !fits {
                    Button { actualSize.toggle() } label: {
                        Image(systemName: actualSize ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .iconButton(size: .compact).accessibilityLabel(actualSize ? "Fit to window" : "Actual size")
                    .help(actualSize ? "Fit to window" : "Actual size")
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .iconButton(size: .compact).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close preview").help("Close (Esc). The screenshot stays attached.")
            }
            picture.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Space.xl).frame(width: sheet.width, height: sheet.height)
        .task(id: item.url) {
            let url = item.url
            let loaded = await Task.detached(priority: .userInitiated) { StagedScreenshotImage.decode(url) }.value
            (decoded, missing) = (loaded, loaded == nil)
        }
    }

    @ViewBuilder private var picture: some View {
        if let decoded {
            let size = decoded.points(at: displayScale)
            let shown = Image(decorative: decoded.image, scale: CGFloat(decoded.image.width) / size.width)
            if actualSize && !fits {
                ScrollView([.horizontal, .vertical]) { shown.onTapGesture { actualSize = false } }
                    .thumbnail(outlined: true)
            } else {
                shown.resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: size.width, maxHeight: size.height).thumbnail(outlined: true)
                    .onTapGesture { if !fits { actualSize = true } }
            }
        } else {
            Rectangle().fill(Theme.canvas).thumbnail(outlined: true)
                .overlay {
                    if missing { Image(systemName: "photo").foregroundStyle(Theme.fg3) } else { ProgressView().controlSize(.small) }
                }
        }
    }

    /// Most of the screen the sheet can take.
    private var room: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: screen.width * 0.9, height: screen.height * 0.85)
    }

    /// The image's own size with the sheet's padding and header around it, within `room` and no smaller than `smallest`.
    private var wanted: CGSize {
        guard let decoded else { return CGSize(width: 860, height: 620) }
        let size = decoded.points(at: displayScale)
        return CGSize(width: size.width + 2 * Space.xl, height: size.height + 2 * Space.xl + Self.header)
    }

    private var fits: Bool { wanted.width <= room.width && wanted.height <= room.height }

    private var sheet: CGSize {
        CGSize(
            width: max(Self.smallest.width, min(wanted.width, room.width)),
            height: max(Self.smallest.height, min(wanted.height, room.height)))
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
        return StagedScreenshotImage(image: image, pixels: CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio))
    }
}

/// The `+` that opens the file chooser for screenshots.
struct AddScreenshotsButton: View {
    var staging: AttachmentStaging
    var disabled = false
    var size: ButtonSize = .small

    var body: some View {
        Button(action: choose) { Image(systemName: "plus") }
            .iconButton(size: size).disabled(disabled).accessibilityLabel("Add screenshots…").help("Add screenshots")
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
