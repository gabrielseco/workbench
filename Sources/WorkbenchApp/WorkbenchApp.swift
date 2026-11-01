import AppKit
import Foundation
import SwiftUI
import WorkbenchCore

@main struct WorkbenchApp: App {
    private static let options = LaunchOptions.from(environment: ProcessInfo.processInfo.environment)
    private static let notifier = SystemNotifier()
    @State private var store = options.makeStore(preferences: UserDefaultsPreferences(), notifier: notifier)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window: a second would restore the same project into the same store.
        Window("Workbench", id: "main") {
            RootView(store: store)
                .task {
                    delegate.drafting = { store.drafting }
                    delegate.stopDrafting = { await store.stopDraftingAndWait() }
                    Self.notifier.onRoute = { route in
                        store.show(route)
                        Self.showWindow()
                    }
                    await Self.options.start(store)
                    store.startPolling()
                    store.startAttentionPolling()
                }
        }
        .commands {
            // There is one window, so File ▸ New has nothing else to mean; the buttons all set the same flag.
            CommandGroup(replacing: .newItem) {
                Button("New goal…") { store.namingGoal = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.project == nil || store.namingGoal)
            }
        }
    }
}

extension WorkbenchApp {
    /// Brings the window forward for a notification's click; a window that was closed is shown again.
    @MainActor static func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.title == "Workbench" {
            window.makeKeyAndOrderFront(nil)
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
