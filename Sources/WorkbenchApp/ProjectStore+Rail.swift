import AppKit
import Foundation
import WorkbenchCore

/// The project rail: the projects the person keeps at hand, one tile each. An app preference, never a file in a project.
extension ProjectStore {
    /// The tiles, in order, each saying why it cannot be opened when it cannot.
    func railTiles() -> [RailProject] {
        RailProjects.tiles(railPaths) { Self.unavailableReason($0) ?? self.refusedPaths[$0] }
    }

    /// A key's choice on the rail (⌘1 the inbox of every project, ⌘2… the projects in the order of the tiles).
    func chooseRailStop(number: Int) async {
        guard let stop = RailProjects.stop(number: number, in: railPaths) else { return }
        await go(to: stop)
    }

    /// The tile above (`-1`) or below (`1`) the one that is open; nothing past either end.
    func moveRailSelection(by step: Int) async {
        let current = allProjects ? nil : project?.root.path
        guard let stop = RailProjects.stop(from: current, by: step, in: railPaths) else { return }
        await go(to: stop)
    }

    private func go(to stop: RailProjects.Stop) async {
        switch stop {
        case .everything: await showAllProjects()
        case .project(let path): await pickRecent(path)
        }
    }

    /// Puts a project on the rail (a project that is opened is kept there). One already on it keeps its place.
    func pin(_ path: String) {
        let next = RailProjects.adding(path, to: railPaths)
        guard next != railPaths else { return }
        railPaths = next
        preferences.railProjects = next
    }

    /// Takes a tile off the rail and only that: the project stays in the recents, its folder and its threads are as they were, and a run it
    /// has goes on. When it is the open one, the window moves to its neighbour, or stays on it when the rail has no other.
    func removeFromRail(_ path: String) async {
        let neighbour = railPaths.firstIndex(of: path).flatMap { index -> String? in
            let rest = RailProjects.removing(path, from: railPaths)
            return rest.isEmpty ? nil : rest[min(index, rest.count - 1)]
        }
        railPaths = RailProjects.removing(path, from: railPaths)
        preferences.railProjects = railPaths
        if path == project?.root.path, let neighbour { await pickRecent(neighbour) }
    }

    func moveOnRail(_ path: String, by step: Int) {
        railPaths = RailProjects.moving(path, by: step, in: railPaths)
        preferences.railProjects = railPaths
    }

    /// `Doctor` from a tile: the project is opened first, since Doctor reads and shows the open project's config.
    func runDoctor(at path: String) async {
        if path != project?.root.path { await pickRecent(path) }
        guard path == project?.root.path else { return }
        await runDoctor()
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
