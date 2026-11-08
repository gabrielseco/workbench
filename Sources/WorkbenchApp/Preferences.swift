import Foundation

/// What the app remembers: the projects it has opened, and nothing about any thread (the log is the state).
protocol Preferences: AnyObject, Sendable {
    /// The project that opens at launch: the latest one opened.
    var projectPath: String? { get set }
    /// Every project opened, most recent first.
    var recentProjects: [String] { get set }
    /// The projects on the rail, in the order the person keeps them. Nil until they have arranged it: the rail then starts from the recents.
    var railProjects: [String]? { get set }
    /// Notifications are paused: nothing is posted, and the count still shows. An app preference, never workbench state.
    var notificationsPaused: Bool { get set }
    /// The identities of attention items the person has seen (a failed task they looked at); the latest 200.
    var seenAttention: [String] { get set }
    /// The identities already announced, per project, so a reason that went away and came back (a CI failure on the same commit) is not
    /// announced twice, and not again after a relaunch. The latest 200.
    var announcedAttention: [String] { get set }
    /// The chat feed (P22) in place of the step screens inside a thread, while it is a preview. Off unless a person turns it on.
    /// The feed's Run settings inspector is shown (P22). On until a person turns it off: the artboard shows it open beside a draft goal.
    var runSettings: Bool { get set }
    /// A person has opened or closed it, so a window too narrow to hold it beside the feed may open it over the feed; until then the default
    /// only shows it where it fits.
    var runSettingsChosen: Bool { get }
}

final class UserDefaultsPreferences: Preferences, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "projectPath"
    private let recentKey = "recentProjects"
    private let railKey = "railProjects"
    private let pausedKey = "notificationsPaused"
    private let seenKey = "seenAttention"
    private let announcedKey = "announcedAttention"
    private let runSettingsKey = "runSettingsShown"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var projectPath: String? {
        get { defaults.string(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }

    var recentProjects: [String] {
        get { defaults.stringArray(forKey: recentKey) ?? [] }
        set { defaults.set(newValue, forKey: recentKey) }
    }

    var railProjects: [String]? {
        get { defaults.object(forKey: railKey) == nil ? nil : defaults.stringArray(forKey: railKey) }
        set { newValue.map { defaults.set($0, forKey: railKey) } ?? defaults.removeObject(forKey: railKey) }
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

    var runSettings: Bool {
        get { (defaults.object(forKey: runSettingsKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: runSettingsKey) }
    }

    var runSettingsChosen: Bool { defaults.object(forKey: runSettingsKey) != nil }
}

final class MemoryPreferences: Preferences, @unchecked Sendable {
    var projectPath: String?
    var recentProjects: [String]
    var railProjects: [String]?
    var notificationsPaused = false
    var runSettings = true { didSet { runSettingsChosen = true } }
    private(set) var runSettingsChosen = false
    var seenAttention: [String] = []
    var announcedAttention: [String] = []
    init(projectPath: String? = nil, recentProjects: [String] = []) {
        self.projectPath = projectPath
        self.recentProjects = recentProjects
    }
}
