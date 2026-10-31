import Foundation
import Testing

@testable import WorkbenchCore

struct TaskScaffoldTests {
    private func project() throws -> Project { Project(root: try Scratch.directory("scaffold")) }

    private func loaded(_ project: Project, _ name: String = "bump") throws -> TaskDefinition {
        try TaskDefinition.parse(String(contentsOf: project.taskFileURL(name), encoding: .utf8), name: name)
    }

    @Test func theScaffoldParsesWithTheSafeDefaults() throws {
        let project = try project()
        let result = try TaskScaffold.create(project: project, name: "bump")
        #expect(result.directory.standardizedFileURL.path == project.taskDirectory("bump").standardizedFileURL.path)
        #expect(result.missing.isEmpty)
        let task = try loaded(project)
        #expect(task.fix == .report && task.batch == 1 && task.schedule == nil)
        #expect(task.include == nil && task.inputs.isEmpty)
        #expect(task.pending == ".workbench/tasks/bump/pending.sh")
        #expect(task.instructions.contains(TaskScaffold.placeholder))
    }

    @Test func theScriptIsExecutableAndListsNothing() throws {
        let project = try project()
        _ = try TaskScaffold.create(project: project, name: "bump")
        let script = project.taskDirectory("bump").appendingPathComponent("pending.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
    }

    @Test func everySettingIsInTheFileAndExplained() throws {
        let project = try project()
        _ = try TaskScaffold.create(project: project, name: "bump")
        let text = try String(contentsOf: project.taskFileURL("bump"), encoding: .utf8)
        for key in TaskDefinition.knownKeys {
            #expect(text.contains("\(key):"), "\(key) is not in the scaffold")
        }
    }

    @Test func includeAndInputsAreWrittenIn() throws {
        let project = try project()
        let result = try TaskScaffold.create(
            project: project, name: "bump", include: ".claude/skills/bump/SKILL.md", inputs: ["countries.txt", "fixtures"])
        let task = try loaded(project)
        #expect(task.include == ".claude/skills/bump/SKILL.md" && task.inputs == ["countries.txt", "fixtures"])
        // Paths that are not there yet are a note, not a refusal.
        #expect(result.missing == [".claude/skills/bump/SKILL.md", "countries.txt", "fixtures"])
    }

    @Test func pathsThatExistAreNotReportedMissing() throws {
        let project = try project()
        try "ROU\n".write(to: project.root.appendingPathComponent("countries.txt"), atomically: true, encoding: .utf8)
        #expect(try TaskScaffold.create(project: project, name: "bump", inputs: ["countries.txt"]).missing.isEmpty)
    }

    @Test func aBadNameOrPathIsRefusedAndNothingIsCreated() throws {
        let project = try project()
        for name in ["../x", "a b", "", "-x", "a/b"] {
            #expect(throws: TaskScaffoldError.invalidName(name)) { try TaskScaffold.create(project: project, name: name) }
        }
        for path in ["/etc/passwd", "../out", "-rf", "~/x", "a//b"] {
            #expect(throws: TaskScaffoldError.self) { try TaskScaffold.create(project: project, name: "bump", include: path) }
            #expect(throws: TaskScaffoldError.self) { try TaskScaffold.create(project: project, name: "bump", inputs: [path]) }
        }
        #expect(!FileManager.default.fileExists(atPath: project.tasksDirectory.path))
    }

    @Test func anInputThatWouldReadBackAsSomethingElseIsRefusedAndNothingIsCreated() throws {
        // A comma splits it in two, `  #` starts a comment, and the parser trims the ends: each reads back as another file.
        for path in ["countries,old.txt", "a  #b.txt", " lead.txt", "trail.txt "] {
            let project = try project()
            #expect(throws: TaskScaffoldError.unrepresentable([path]), "\(path)") {
                try TaskScaffold.create(project: project, name: "bump", inputs: [path])
            }
            #expect(!FileManager.default.fileExists(atPath: project.tasksDirectory.path), "\(path)")
        }
    }

    @Test func anInputThatReadsBackAsGivenIsKeptEvenWithOddCharacters() throws {
        // The check is the round trip, not a list of characters: these are all read back exactly.
        for path in ["my list.txt", "a[1].txt", "it's.txt", "\"q\".txt", "dir/a#b.txt"] {
            let project = try project()
            _ = try TaskScaffold.create(project: project, name: "bump", inputs: [path])
            #expect(try loaded(project).inputs == [path], "\(path)")
        }
    }

    @Test func anIncludeIsWrittenOnlyIfItReadsBackAsGiven() throws {
        for path in ["skill.md", "dir/with,comma.md", "a  #b.md", "\"q\".md", "it's.md"] {
            let project = try project()
            if (try? TaskScaffold.create(project: project, name: "bump", include: path)) != nil {
                #expect(try loaded(project).include == path, "\(path)")
            } else {
                #expect(!FileManager.default.fileExists(atPath: project.tasksDirectory.path), "\(path)")
            }
        }
        #expect(throws: TaskScaffoldError.self) {
            try TaskScaffold.create(project: try project(), name: "bump", include: "a  #b.md")
        }
    }

    @Test func claimingAFolderIsExclusiveAndNeverTouchesWhatIsThere() throws {
        let project = try project()
        try FileManager.default.createDirectory(at: project.tasksDirectory, withIntermediateDirectories: true)
        let directory = project.taskDirectory("bump")
        try TaskScaffold.claim(directory, name: "bump")
        try "mine".write(to: directory.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
        // The second of two creations that both passed the "does it exist" check.
        #expect(throws: TaskScaffoldError.exists(".workbench/tasks/bump")) { try TaskScaffold.claim(directory, name: "bump") }
        #expect(try String(contentsOf: directory.appendingPathComponent("task.md"), encoding: .utf8) == "mine")
    }

    @Test func aLinkThatLeavesTheProjectTakesNothing() throws {
        let project = try project()
        let outside = try Scratch.directory("outside-tasks")
        try FileManager.default.createDirectory(at: project.workbenchDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.tasksDirectory, withDestinationURL: outside)
        #expect(throws: TaskScaffoldError.outsideProject(".workbench/tasks")) {
            try TaskScaffold.create(project: project, name: "bump")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

        let other = try self.project()
        let away = try Scratch.directory("outside-workbench")
        try FileManager.default.createSymbolicLink(at: other.workbenchDirectory, withDestinationURL: away)
        #expect(throws: TaskScaffoldError.outsideProject(".workbench/tasks")) {
            try TaskScaffold.create(project: other, name: "bump")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: away.path).isEmpty)
    }

    @Test func anExistingTaskIsNeverOverwritten() throws {
        let project = try project()
        _ = try TaskScaffold.create(project: project, name: "bump")
        try "---\nfix: pr\n---\nMine.\n".write(to: project.taskFileURL("bump"), atomically: true, encoding: .utf8)
        #expect(throws: TaskScaffoldError.exists(".workbench/tasks/bump")) {
            try TaskScaffold.create(project: project, name: "bump")
        }
        #expect(try loaded(project).instructions == "Mine.")
        // Not even an empty folder is taken over.
        try FileManager.default.createDirectory(at: project.taskDirectory("empty"), withIntermediateDirectories: true)
        #expect(throws: TaskScaffoldError.self) { try TaskScaffold.create(project: project, name: "empty") }
    }

    @Test func theScaffoldCannotBeApprovedUntilTheInstructionsAreWritten() async throws {
        let project = try project()
        _ = try TaskScaffold.create(project: project, name: "bump")
        let library = TaskLibrary(project: project)
        // It loads and lists as a draft.
        #expect(library.names() == ["bump"] && library.summary("bump").problem == nil)
        await #expect(throws: TaskFileError.placeholder) { try await library.approve("bump") }
        #expect(try TaskRunLog(project: project, name: "bump").history().approvedHash == nil)

        let text = try String(contentsOf: project.taskFileURL("bump"), encoding: .utf8)
        let written = text.components(separatedBy: "\n")
            .filter { !$0.contains(TaskScaffold.placeholder) && $0 != "Delete this line when you have." }
        try (written + ["Bump the next country."]).joined(separator: "\n")
            .write(to: project.taskFileURL("bump"), atomically: true, encoding: .utf8)
        _ = try await library.approve("bump")
        #expect(library.summary("bump").approval == .approved)
    }
}

@Suite(.processGate) struct TaskScaffoldScriptTests {
    @Test func theScaffoldsScriptRunsAndListsNoUnits() async throws {
        let project = Project(root: try Scratch.directory("scaffold-run"))
        _ = try TaskScaffold.create(project: project, name: "bump")
        let units = try await PendingUnits.run(
            script: ".workbench/tasks/bump/pending.sh", project: project,
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()])
        #expect(units.isEmpty)
    }
}
