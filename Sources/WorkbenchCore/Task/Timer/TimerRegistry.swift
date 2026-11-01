import Foundation

/// The projects that have a timer installed on this machine, read from the agents `task timer install` wrote
/// (`~/Library/LaunchAgents/com.workbench.task-tick.<slug>.plist`): there is no other registry of projects, and an agent's own file
/// names the folder it runs in.
public enum TimerRegistry {
    public struct Entry: Equatable, Sendable {
        /// `com.workbench.task-tick.<slug>`.
        public var label: String
        /// The project folder the agent runs in.
        public var root: URL
    }

    static let prefix = "com.workbench.task-tick."

    /// One entry per agent file that names a folder, sorted by label so a pass over them is the same every time. Two agents for one
    /// folder are one entry.
    public static func projects(home: URL) -> [Entry] {
        let folder = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var seen = Set<String>()
        var entries: [Entry] = []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".plist") {
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let directory = plist["WorkingDirectory"] as? String, directory.hasPrefix("/"), seen.insert(directory).inserted
            else { continue }
            let label = String(name.dropLast(".plist".count))
            entries.append(Entry(label: label, root: URL(fileURLWithPath: directory, isDirectory: true)))
        }
        return entries
    }
}
