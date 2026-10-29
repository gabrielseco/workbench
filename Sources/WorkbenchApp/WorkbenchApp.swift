import AppKit
import Foundation
import SwiftUI

@main struct WorkbenchApp: App {
    private static let options = LaunchOptions.from(environment: ProcessInfo.processInfo.environment)
    @State private var store = options.makeStore(preferences: UserDefaultsPreferences())
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window: a second would restore the same project into the same store.
        Window("Workbench", id: "main") {
            RootView(store: store)
                .task {
                    delegate.beforeQuit = { store.stopDrafting() }
                    await Self.options.start(store)
                    store.startPolling()
                }
        }
    }
}

/// Run from `swift run` the process has no bundle, so it asks to be a regular app with a window and a menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Ends a goal draft that is still running: its agent runs in a process group of its own and would outlive the window.
    var beforeQuit: (@MainActor () -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { beforeQuit?() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
