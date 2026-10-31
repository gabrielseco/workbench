import Foundation
import Testing

@testable import WorkbenchCore

struct TaskInputsTests {
    @Test func inputsCanBeAnyFormatAndAreReadAsText() throws {
        let fx = try TaskFixture()
        try fx.write("countries.txt", "41. XKX - Kosovo [Europe] v1 -> v3 | 1\n")
        try fx.write("fixtures/a.json", "{\"id\": 1}")
        try fx.write("fixtures/deep/b.csv", "a,b\n1,2\n")
        let inputs = try TaskFiles(project: fx.project).inputs(["countries.txt", "fixtures"])
        #expect(inputs.map(\.path) == ["countries.txt", "fixtures/a.json", "fixtures/deep/b.csv"])
        #expect(inputs[0].text.contains("Kosovo"))
    }

    @Test func aMissingInputIsRefused() throws {
        let fx = try TaskFixture()
        #expect(throws: TaskFileError.notFound("nope.txt")) { try TaskFiles(project: fx.project).inputs(["nope.txt"]) }
    }

    @Test func aLinkThatLeavesTheProjectIsRefused() throws {
        let fx = try TaskFixture()
        let outside = try Scratch.directory("outside")
        try "secret".write(to: outside.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fx.project.root.appendingPathComponent("link.txt"), withDestinationURL: outside.appendingPathComponent("s.txt"))
        try FileManager.default.createSymbolicLink(
            at: fx.project.root.appendingPathComponent("linkdir"), withDestinationURL: outside)
        let files = TaskFiles(project: fx.project)
        #expect(throws: TaskFileError.outsideProject("link.txt")) { try files.inputs(["link.txt"]) }
        #expect(throws: TaskFileError.outsideProject("linkdir")) { try files.inputs(["linkdir"]) }
    }

    @Test func oversizedInputsAreRefused() throws {
        let fx = try TaskFixture()
        try fx.write("big.txt", String(repeating: "x", count: TaskFiles.maxInputBytes + 1))
        #expect(throws: TaskFileError.self) { try TaskFiles(project: fx.project).inputs(["big.txt"]) }
    }

    @Test func tooManyFilesInADirectoryAreRefused() throws {
        let fx = try TaskFixture()
        for index in 0...TaskFiles.maxInputFiles { try fx.write("many/f\(index).txt", "x") }
        #expect(throws: TaskFileError.tooMany("many", limit: TaskFiles.maxInputFiles)) {
            try TaskFiles(project: fx.project).inputs(["many"])
        }
    }

    @Test func theFileLimitCountsAcrossAllTheInputs() throws {
        let fx = try TaskFixture()
        for index in 0..<150 {
            try fx.write("one/f\(index).txt", "x")
            try fx.write("two/f\(index).txt", "x")
        }
        #expect(throws: TaskFileError.self) { try TaskFiles(project: fx.project).inputs(["one", "two"]) }
        #expect(try TaskFiles(project: fx.project).inputs(["one"]).count == 150)
    }

    @Test(.timeLimit(.minutes(1))) func aPipeIsRefusedAsAnInputAndAsAScript() throws {
        let fx = try TaskFixture()
        let fifo = fx.project.root.appendingPathComponent("pipe").path
        try #require(mkfifo(fifo, 0o600) == 0)
        let files = TaskFiles(project: fx.project)
        #expect(throws: TaskFileError.unreadable("pipe")) { try files.inputs(["pipe"]) }
        #expect(throws: TaskFileError.unreadable("pipe")) { try files.read("pipe", limit: 100) }
    }

    @Test(.enabled(if: geteuid() != 0, "root reads a directory with no permissions"))
    func aDirectoryThatCannotBeListedIsRefusedNotShortened() throws {
        let fx = try TaskFixture()
        try fx.write("d/ok.txt", "y")
        try fx.write("d/locked/secret.txt", "z")
        let locked = fx.project.root.appendingPathComponent("d/locked").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        #expect(throws: TaskFileError.unreadable("d")) { try TaskFiles(project: fx.project).inputs(["d"]) }
    }

    @Test func hiddenFilesInADirectoryAreSkipped() throws {
        let fx = try TaskFixture()
        try fx.write("d/.secret", "x")
        try fx.write("d/ok.txt", "y")
        #expect(try TaskFiles(project: fx.project).inputs(["d"]).map(\.path) == ["d/ok.txt"])
    }
}
