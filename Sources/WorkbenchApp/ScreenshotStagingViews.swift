import AppKit
import SwiftUI
import WorkbenchCore

/// The staged screenshots as small thumbnails, each with a remove button: the new-thread screen's and the chat composer's.
struct StagedThumbnails: View {
    var staging: AttachmentStaging

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(Array(staging.items.enumerated()), id: \.element.id) { index, item in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = item.thumbnail { Image(nsImage: image).resizable().scaledToFill() } else {
                            Theme.grey.opacity(0.3)
                        }
                    }
                    .frame(width: 44, height: 44).thumbnail()
                    Button { staging.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Remove screenshot \(index + 1)").padding(Space.xxs)
                }
            }
            Spacer()
        }
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
