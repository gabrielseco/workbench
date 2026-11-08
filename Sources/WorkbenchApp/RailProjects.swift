import Foundation

/// What one project tile says: the badge and why it has one. Failed beats needs you, and needs you beats running (P26): the badge is the
/// most urgent thing the project holds, and the count is how many of those.
enum RailBadge: Equatable {
    case none
    case running
    case needsYou(Int)
    case failed(Int)

    static func from(needsYou: Int, failed: Int, running: Bool) -> RailBadge {
        if failed > 0 { return .failed(failed) }
        if needsYou > 0 { return .needsYou(needsYou) }
        return running ? .running : .none
    }

    /// The tile's name for assistive technology and `scripts/verify-app.sh`: `api, 1 failed`, `project, 4 need you`, `mobile, running`.
    func label(for name: String) -> String {
        switch self {
        case .none: name
        case .running: "\(name), running"
        case .needsYou(let count): "\(name), \(count) need you"
        case .failed(let count): "\(name), \(count) failed"
        }
    }
}

/// One tile of the project rail: a project the person keeps at hand.
struct RailProject: Equatable, Identifiable {
    var path: String
    /// The folder name, with its parent when two tiles share one.
    var name: String
    /// Two letters on the tile.
    var initials: String
    /// Why the project cannot be opened now (the folder is gone, it is no longer a git repository); nil when it can.
    var unavailable: String?
    var id: String { path }
}

/// The ordered list of projects behind the rail (an app preference, never a file in a project) and what is shown from it. Pure, so the
/// ordering, the seeding and the names are tested without a window.
enum RailProjects {
    static let limit = 20

    /// The list for a person who has never arranged the rail: the recents, in the order they were opened, oldest first so that a tile
    /// does not jump each time another project is opened.
    static func seed(fromRecents recents: [String]) -> [String] { Array(recents.reversed()) }

    /// `path` at the end of the list, once. A project already on the rail keeps its place.
    static func adding(_ path: String, to list: [String]) -> [String] {
        guard !list.contains(path) else { return list }
        return Array((list + [path]).prefix(limit))
    }

    static func removing(_ path: String, from list: [String]) -> [String] { list.filter { $0 != path } }

    /// `path` moved one place towards the start (`-1`) or the end (`1`); the same list at either edge or when it is not there.
    static func moving(_ path: String, by step: Int, in list: [String]) -> [String] {
        guard let index = list.firstIndex(of: path) else { return list }
        let target = index + step
        guard list.indices.contains(target) else { return list }
        var moved = list
        moved.swapAt(index, target)
        return moved
    }

    /// Where a key takes you: the rail from the top, the inbox of every project first (`nil`), then each project (its path). `number` is the
    /// 1-based key (⌘1 is the inbox of all); nil when the rail has no such stop.
    enum Stop: Equatable { case everything, project(String) }

    static func stop(number: Int, in paths: [String]) -> Stop? {
        guard number >= 1, number <= paths.count + 1 else { return nil }
        return number == 1 ? .everything : .project(paths[number - 2])
    }

    /// The stop `step` places from `current` (`nil` is the inbox of all), stopping at either end: the rail is a list, not a loop. A
    /// project that cannot be opened is passed over, else a step onto it is refused and every later step aims at it again.
    static func stop(from current: String?, by step: Int, in paths: [String], skipping unavailable: Set<String> = []) -> Stop? {
        let stops: [Stop] = [.everything] + paths.map(Stop.project)
        let here = current.flatMap { path in paths.firstIndex(of: path).map { $0 + 1 } } ?? 0
        var target = here + (step < 0 ? -1 : 1)
        while stops.indices.contains(target) {
            if case .project(let path) = stops[target], unavailable.contains(path) {
                target += step < 0 ? -1 : 1
            } else {
                return stops[target]
            }
        }
        return nil
    }

    /// Two letters from a folder name: the first letters of its first two words (`expenses-backend` is `eb`), else its first two
    /// letters (`project` is `pr`), lower case as the design has them. A name with one letter or none is padded by what it has.
    static func initials(of name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.count >= 2, let first = words[0].first, let second = words[1].first { return "\(first)\(second)".lowercased() }
        return String((words.first ?? name).prefix(2)).lowercased()
    }

    /// The tiles for `paths`, in order. Two projects with one folder name are told apart by their parent folder, as the project card does.
    static func tiles(_ paths: [String], unavailable: (String) -> String?) -> [RailProject] {
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        return paths.enumerated().map { index, path in
            let url = URL(fileURLWithPath: path)
            let shared = names.filter { $0 == names[index] }.count > 1
            let name = shared ? "\(names[index]) (\(url.deletingLastPathComponent().lastPathComponent))" : names[index]
            return RailProject(path: path, name: name, initials: initials(of: names[index]), unavailable: unavailable(path))
        }
    }
}
