import AppKit
import Foundation
import WorkbenchCore

/// How the app was started. `WORKBENCH_APP_PROJECT` names a project to open instead of the remembered one, and then the app neither
/// reads nor writes its preferences: that is how `scripts/verify-app.sh` shows a fixture project without touching what a person set.
struct LaunchOptions: Equatable {
    var project: URL?
    /// `WORKBENCH_SKIP_LOGIN_PATH` set: keep the `PATH` the app was given instead of asking the login shell. Only for a test that
    /// must not read a profile; a fixture launch does ask, so verification sees what a person's launch sees.
    var skipsLoginPath = false
    /// `WORKBENCH_APPEARANCE` set to `light` or `dark`: this launch draws in that appearance whatever the system is set to, so a check can
    /// show both. Nothing outside the process changes and no preference is written; unset or anything else is the system's.
    var appearance: Appearance?
    /// `WORKBENCH_APP_OPEN` set to a modal's name: it is open once the project has loaded, so `scripts/verify-app.sh` can shoot the ones
    /// a button does not reach (they open from a menu, or from a round that needs Codex). Unset or an unknown name opens nothing.
    var opens: LaunchModal?

    enum Appearance: Equatable {
        case light, dark

        init?(_ value: String?) {
            switch value?.lowercased() {
            case "light": self = .light
            case "dark": self = .dark
            default: return nil
            }
        }

        var nsAppearance: NSAppearance? { NSAppearance(named: self == .light ? .aqua : .darkAqua) }
    }

    static func from(environment: [String: String]) -> LaunchOptions {
        let skips = environment["WORKBENCH_SKIP_LOGIN_PATH"].map { !$0.isEmpty } ?? false
        let appearance = Appearance(environment["WORKBENCH_APPEARANCE"])
        let opens = environment["WORKBENCH_APP_OPEN"].flatMap(LaunchModal.init(rawValue:))
        guard let path = environment["WORKBENCH_APP_PROJECT"], !path.isEmpty else {
            return LaunchOptions(project: nil, skipsLoginPath: skips, appearance: appearance, opens: opens)
        }
        return LaunchOptions(
            project: URL(fileURLWithPath: path), skipsLoginPath: skips, appearance: appearance, opens: opens)
    }

    /// The store for these options: the real preferences normally, a throwaway set when a project was named.
    @MainActor func makeStore(preferences: Preferences, notifier: Notifier = NullNotifier()) -> ProjectStore {
        // A fixture launch (a project named) posts nothing and asks for no permission.
        if project == nil { return ProjectStore(preferences: preferences, notifier: notifier) }
        return ProjectStore(preferences: MemoryPreferences())
    }

    /// What the window does when it appears: open the named project, else restore the remembered one. The `PATH` comes first, so
    /// nothing the window starts is looked for on the system's bare one.
    @MainActor func start(
        _ store: ProjectStore, applyLoginPath: @MainActor () async -> Void = { await LoginShellPath.applyToEnvironment() },
        setAppearance: @MainActor (NSAppearance?) -> Void = { NSApplication.shared.appearance = $0 }
    ) async {
        if let appearance { setAppearance(appearance.nsAppearance) }
        if !skipsLoginPath { await applyLoginPath() }
        if let project { await store.open(project) } else { await store.restore() }
        if let opens { await store.show(opens) }
    }
}
