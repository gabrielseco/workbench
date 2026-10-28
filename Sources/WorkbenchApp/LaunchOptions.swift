import Foundation

/// How the app was started. `WORKBENCH_APP_PROJECT` names a project to open instead of the remembered one, and then the app neither
/// reads nor writes its preferences: that is how `scripts/verify-app.sh` shows a fixture project without touching what a person set.
struct LaunchOptions: Equatable {
    var project: URL?

    static func from(environment: [String: String]) -> LaunchOptions {
        guard let path = environment["WORKBENCH_APP_PROJECT"], !path.isEmpty else { return LaunchOptions(project: nil) }
        return LaunchOptions(project: URL(fileURLWithPath: path))
    }

    /// The store for these options: the real preferences normally, a throwaway set when a project was named.
    @MainActor func makeStore(preferences: Preferences) -> ProjectStore {
        ProjectStore(preferences: project == nil ? preferences : MemoryPreferences())
    }

    /// What the window does when it appears: open the named project, else restore the remembered one.
    @MainActor func start(_ store: ProjectStore) async {
        if let project { await store.open(project) } else { await store.restore() }
    }
}
