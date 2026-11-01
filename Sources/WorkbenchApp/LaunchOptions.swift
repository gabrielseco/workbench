import Foundation
import WorkbenchCore

/// How the app was started. `WORKBENCH_APP_PROJECT` names a project to open instead of the remembered one, and then the app neither
/// reads nor writes its preferences: that is how `scripts/verify-app.sh` shows a fixture project without touching what a person set.
struct LaunchOptions: Equatable {
    var project: URL?
    /// `WORKBENCH_SKIP_LOGIN_PATH` set: keep the `PATH` the app was given instead of asking the login shell. Only for a test that
    /// must not read a profile; a fixture launch does ask, so verification sees what a person's launch sees.
    var skipsLoginPath = false

    static func from(environment: [String: String]) -> LaunchOptions {
        let skips = environment["WORKBENCH_SKIP_LOGIN_PATH"].map { !$0.isEmpty } ?? false
        guard let path = environment["WORKBENCH_APP_PROJECT"], !path.isEmpty else {
            return LaunchOptions(project: nil, skipsLoginPath: skips)
        }
        return LaunchOptions(project: URL(fileURLWithPath: path), skipsLoginPath: skips)
    }

    /// The store for these options: the real preferences normally, a throwaway set when a project was named.
    @MainActor func makeStore(preferences: Preferences, notifier: Notifier = NullNotifier()) -> ProjectStore {
        // A fixture launch (a project named) posts nothing and asks for no permission.
        project == nil
            ? ProjectStore(preferences: preferences, notifier: notifier) : ProjectStore(preferences: MemoryPreferences())
    }

    /// What the window does when it appears: open the named project, else restore the remembered one. The `PATH` comes first, so
    /// nothing the window starts is looked for on the system's bare one.
    @MainActor func start(
        _ store: ProjectStore, applyLoginPath: @MainActor () async -> Void = { await LoginShellPath.applyToEnvironment() }
    ) async {
        if !skipsLoginPath { await applyLoginPath() }
        if let project { await store.open(project) } else { await store.restore() }
    }
}
