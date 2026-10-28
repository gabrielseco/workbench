import Foundation

/// What the app remembers: the projects it has opened, and nothing about any thread (the log is the state).
protocol Preferences: AnyObject, Sendable {
    /// The project that opens at launch: the latest one opened.
    var projectPath: String? { get set }
    /// Every project opened, most recent first.
    var recentProjects: [String] { get set }
}

final class UserDefaultsPreferences: Preferences, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "projectPath"
    private let recentKey = "recentProjects"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var projectPath: String? {
        get { defaults.string(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }

    var recentProjects: [String] {
        get { defaults.stringArray(forKey: recentKey) ?? [] }
        set { defaults.set(newValue, forKey: recentKey) }
    }
}

final class MemoryPreferences: Preferences, @unchecked Sendable {
    var projectPath: String?
    var recentProjects: [String]
    init(projectPath: String? = nil, recentProjects: [String] = []) {
        self.projectPath = projectPath
        self.recentProjects = recentProjects
    }
}
