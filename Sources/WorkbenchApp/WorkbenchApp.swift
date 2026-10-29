import AppKit
import Foundation
import SwiftUI
import WorkbenchCore

@main struct WorkbenchApp: App {
    private static let options = LaunchOptions.from(environment: ProcessInfo.processInfo.environment)
    @State private var store = options.makeStore(preferences: UserDefaultsPreferences())
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window: a second would restore the same project into the same store.
        Window("Workbench", id: "main") {
            RootView(store: store)
                .task {
                    delegate.drafting = { store.drafting }
                    delegate.stopDrafting = { await store.stopDraftingAndWait() }
                    await Self.options.start(store)
                    store.startPolling()
                }
        }
    }
}

/// Run from `swift run` the process has no bundle, so it asks to be a regular app with a window and a menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether a goal draft is running, and a way to end it and wait: its agent runs in a process group of its own and would
    /// outlive the window, so a quit waits for it (the store gives up after a deadline).
    var drafting: @MainActor () -> Bool = { false }
    var stopDrafting: (@MainActor () async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard drafting(), let stop = stopDrafting else { return .terminateNow }
        Task { @MainActor in
            await stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
