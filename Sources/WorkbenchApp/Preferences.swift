import Foundation

/// What the app remembers: the one project, and nothing about any thread (the log is the state).
protocol Preferences: AnyObject, Sendable {
    var projectPath: String? { get set }
}

final class UserDefaultsPreferences: Preferences, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "projectPath"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var projectPath: String? {
        get { defaults.string(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

final class MemoryPreferences: Preferences, @unchecked Sendable {
    var projectPath: String?
    init(projectPath: String? = nil) { self.projectPath = projectPath }
}
