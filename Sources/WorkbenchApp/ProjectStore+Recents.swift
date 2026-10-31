import Foundation
import WorkbenchCore

/// The projects the app has opened: the card behind the project pill. An app preference, never a file in a project.
extension ProjectStore {
    nonisolated static let recentLimit = 10

    /// The old single remembered path counts as the latest project, so an upgrade loses nothing.
    nonisolated static func merged(_ recents: [String], _ latest: String?) -> [String] {
        var seen = Set<String>()
        return (recents + [latest].compactMap { $0 }).filter { seen.insert($0).inserted }.prefix(recentLimit).map { $0 }
    }

    /// Puts `path` first, once, and keeps the newest ten.
    func remember(_ path: String) {
        recentPaths = Array(([path] + recentPaths.filter { $0 != path }).prefix(Self.recentLimit))
        preferences.recentProjects = recentPaths
    }

    func forget(_ path: String) {
        refusedPaths[path] = nil
        recentPaths.removeAll { $0 == path }
        preferences.recentProjects = recentPaths
    }

    /// The list for the menu: folder names (with the parent folder when two share one), the current project, the one with a run,
    /// and why a project cannot be opened now.
    func recentProjects() -> [RecentProject] {
        let names = recentPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        return recentPaths.enumerated().map { index, path in
            let url = URL(fileURLWithPath: path)
            let shared = names.filter { $0 == names[index] }.count > 1
            let name = shared ? "\(names[index]) (\(url.deletingLastPathComponent().lastPathComponent))" : names[index]
            return RecentProject(
                path: path, name: name, isCurrent: path == project?.root.path,
                isRunning: runningProjectPath == path, unavailable: Self.unavailableReason(path) ?? refusedPaths[path])
        }
    }

    nonisolated static func unavailableReason(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "The folder is gone."
        }
        guard FileManager.default.fileExists(atPath: path + "/.git") else { return "It is no longer a git repository." }
        return nil
    }

    /// Opens a project from the list. One that cannot be opened is refused without touching the one that is open.
    func switchTo(_ path: String) async {
        if let reason = Self.unavailableReason(path) {
            actionError = "\(URL(fileURLWithPath: path).lastPathComponent): \(reason)"
            return
        }
        actionError = nil
        // Git decides whether it is a repository: a `.git` that points nowhere passes the check above and must not close the
        // project that is open, which `open` does when it fails.
        do { _ = try await Project.locate(from: URL(fileURLWithPath: path), git: try GitRunner.discover()) } catch {
            refusedPaths[path] = "It is not a usable git repository."
            actionError = "\(URL(fileURLWithPath: path).lastPathComponent): it is not a usable git repository."
            return
        }
        await open(URL(fileURLWithPath: path))
    }

    /// A row of the project card: the open project only closes the card, another is switched to; a refusal keeps the card up to say why.
    func pickRecent(_ path: String) async {
        guard path != project?.root.path else {
            pickingProject = false
            return
        }
        await switchTo(path)
    }

    /// "Choose folder…": the panel, then the folder it gave. Cancelling it changes nothing.
    func chooseFolder() async {
        pickingProject = false
        guard let url = folderChooser() else { return }
        actionError = nil
        await open(url)
    }

    /// The card's rows for what is typed in its search field: a name or a path that contains it, in the list's order.
    nonisolated static func filter(_ entries: [RecentProject], _ query: String) -> [RecentProject] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.path.localizedCaseInsensitiveContains(needle)
        }
    }
}
