import AppKit
import SwiftUI

@main struct WorkbenchApp: App {
    @State private var store = ProjectStore(preferences: UserDefaultsPreferences())
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window: a second would restore the same project into the same store.
        Window("Workbench", id: "main") {
            RootView(store: store)
                .task {
                    await store.restore()
                    store.startPolling()
                }
        }
    }
}

/// Run from `swift run` the process has no bundle, so it asks to be a regular app with a window and a menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
