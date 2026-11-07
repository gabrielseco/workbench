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
                .defaultButtonStyle()
                .task {
                    delegate.liveWork = { store.liveWork }
                    delegate.stopWork = { await store.stopWorkAndWait() }
                    Self.notifier.onRoute = { route, project in
                        store.show(route, project: project)
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
                Button("New goal…") { store.beginNewGoal() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.project == nil)
                Button("New task…") { store.beginNewTask() }
                    .keyboardShortcut("n", modifiers: [.shift, .command])
                    .disabled(store.project == nil)
            }
            // The one settings the app has are the project's agents, so the standard ⌘, opens them.
            CommandGroup(replacing: .appSettings) {
                Button("Agents…") { store.showingAgents.toggle() }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(store.project == nil)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Run settings", isOn: Binding(get: { store.runSettingsShowing }, set: { _ in store.toggleRunSettings() }))
                    .keyboardShortcut("r", modifiers: [.option, .command])
            }
        }

        // The app stays resident when the window is closed, and this says when it needs you.
        MenuBarExtra {
            MenuBarPopover(store: store).defaultButtonStyle()
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
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
    /// What a quit would end (a thread's run, a task's run), as a line, and a way to end it and wait.
    var liveWork: @MainActor () -> String? = { nil }
    var stopWork: (@MainActor () async -> Void)?

    /// A closed window does not end the app: a run goes on, and the status item keeps watching.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let work = liveWork()
        guard work != nil else { return .terminateNow }
        if let work {
            let alert = NSAlert()
            alert.messageText = "Quit Workbench?"
            alert.informativeText = work + " " + QuitPrompt.detail
            alert.addButton(withTitle: "Stop and quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        let stopWork = self.stopWork
        Task { @MainActor in
            await stopWork?()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
