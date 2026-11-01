import Foundation
import Testing

@testable import WorkbenchCore

struct TimerRegistryTests {
    private func agents(_ home: URL) throws -> URL {
        let folder = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func plist(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    private func install(_ project: Project, in home: URL) throws {
        let paths = TimerPaths(project: project, home: home)
        try FileManager.default.createDirectory(at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = TimerFiles.plist(paths: paths, project: project, interval: 900)
        try text.write(to: paths.plist, atomically: true, encoding: .utf8)
    }

    @Test func theProjectsOfTheInstalledTimersAreListedInOrder() throws {
        let home = try Scratch.directory("home")
        let one = Project(root: try Scratch.directory("one"))
        let two = Project(root: try Scratch.directory("two"))
        try install(two, in: home)
        try install(one, in: home)
        let entries = TimerRegistry.projects(home: home)
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.root.path)) == [one.root.path, two.root.path])
        #expect(entries.map(\.label) == entries.map(\.label).sorted())
        #expect(entries.allSatisfy { $0.label.hasPrefix("com.workbench.task-tick.") })
    }

    @Test func otherFilesAndDamagedOnesAreNotProjects() throws {
        let home = try Scratch.directory("home")
        let folder = try agents(home)
        let broken = folder.appendingPathComponent("com.workbench.task-tick.broken.plist")
        try "not a plist".write(to: broken, atomically: true, encoding: .utf8)
        try "<plist/>".write(to: folder.appendingPathComponent("com.someone.else.plist"), atomically: true, encoding: .utf8)
        let relative = ["Label": "x", "WorkingDirectory": "relative/path"] as [String: Any]
        try plist(relative).write(to: folder.appendingPathComponent("com.workbench.task-tick.relative.plist"))
        let missing = ["Label": "y"] as [String: Any]
        try plist(missing).write(to: folder.appendingPathComponent("com.workbench.task-tick.nodir.plist"))
        #expect(TimerRegistry.projects(home: home).isEmpty)
        #expect(TimerRegistry.projects(home: try Scratch.directory("empty-home")).isEmpty, "no agents folder at all")
    }

    @Test func aParentRepositoryIsNotTheProjectATimerWasInstalledFor() throws {
        let home = try Scratch.directory("home")
        let outer = try Scratch.directory("outer")
        let inner = outer.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try install(Project(root: inner), in: home)
        let entry = try #require(TimerRegistry.projects(home: home).first)
        #expect(entry.isTheProject(Project(root: inner)))
        // The child lost its repository: searching upward finds the parent, which is another project.
        #expect(!entry.isTheProject(Project(root: outer)))
        // The same folder by another spelling (a link, a trailing slash) is the same project.
        let link = try Scratch.directory("links").appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inner)
        #expect(entry.isTheProject(Project(root: link)))
    }

    @Test func twoAgentsForOneFolderAreOneEntry() throws {
        let home = try Scratch.directory("home")
        let project = Project(root: try Scratch.directory("one"))
        try install(project, in: home)
        let folder = try agents(home)
        let copy = folder.appendingPathComponent("com.workbench.task-tick.copy.plist")
        let original = TimerPaths(project: project, home: home).plist
        try FileManager.default.copyItem(at: original, to: copy)
        #expect(TimerRegistry.projects(home: home).count == 1)
    }
}
