import Foundation

/// What the app remembers: the projects it has opened, and nothing about any thread (the log is the state).
protocol Preferences: AnyObject, Sendable {
    /// The project that opens at launch: the latest one opened.
    var projectPath: String? { get set }
    /// Every project opened, most recent first.
    var recentProjects: [String] { get set }
    /// Notifications are paused: nothing is posted, and the count still shows. An app preference, never workbench state.
    var notificationsPaused: Bool { get set }
    /// The identities of attention items the person has seen (a failed task they looked at); the latest 200.
    var seenAttention: [String] { get set }
    /// The identities already announced, per project, so a reason that went away and came back (a CI failure on the same commit) is not
    /// announced twice, and not again after a relaunch. The latest 200.
    var announcedAttention: [String] { get set }
}

final class UserDefaultsPreferences: Preferences, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "projectPath"
    private let recentKey = "recentProjects"
    private let pausedKey = "notificationsPaused"
    private let seenKey = "seenAttention"
    private let announcedKey = "announcedAttention"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var projectPath: String? {
        get { defaults.string(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }

    var recentProjects: [String] {
        get { defaults.stringArray(forKey: recentKey) ?? [] }
        set { defaults.set(newValue, forKey: recentKey) }
    }

    var notificationsPaused: Bool {
        get { defaults.bool(forKey: pausedKey) }
        set { defaults.set(newValue, forKey: pausedKey) }
    }

    var seenAttention: [String] {
        get { defaults.stringArray(forKey: seenKey) ?? [] }
        set { defaults.set(newValue, forKey: seenKey) }
    }

    var announcedAttention: [String] {
        get { defaults.stringArray(forKey: announcedKey) ?? [] }
        set { defaults.set(newValue, forKey: announcedKey) }
    }
}

final class MemoryPreferences: Preferences, @unchecked Sendable {
    var projectPath: String?
    var recentProjects: [String]
    var notificationsPaused = false
    var seenAttention: [String] = []
    var announcedAttention: [String] = []
    init(projectPath: String? = nil, recentProjects: [String] = []) {
        self.projectPath = projectPath
        self.recentProjects = recentProjects
    }
}
