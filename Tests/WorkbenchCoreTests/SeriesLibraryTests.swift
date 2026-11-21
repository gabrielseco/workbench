import Foundation
import Testing

@testable import WorkbenchCore

private let goalText = """
    ---
    title: Add the thing
    budget_usd: 2.00
    turn_timeout_min: 20
    ---

    ## Request

    Add the thing.

    ## Criteria

    - [c1] The thing exists.
      - proof: a test

    ## Out of scope

    - Everything else.
    """

/// A series folder in a fixture project whose own checkout is also the step's project.
private struct SeriesFixture {
    var fx: RunnerFixture
    var library: SeriesLibrary
    var directory: URL

    init(steps: String = "project: PROJECT\ngoal: p1.md\n") async throws {
        fx = try await RunnerFixture()
        library = SeriesLibrary(project: fx.project)
        directory = fx.project.seriesDirectory("s")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write("series.md", "## 1\n" + steps.replacingOccurrences(of: "PROJECT", with: fx.repo.path))
        try write("p1.md", goalText)
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

@Suite(.processGate) struct SeriesLibraryTests {
    @Test func aSeriesLoadsWithItsGoalsAndIsListed() async throws {
        let s = try await SeriesFixture()
        #expect(s.library.names() == ["s"])
        let loaded = try s.library.load("s")
        #expect(loaded.goals[1]?.title == "Add the thing")
        #expect(loaded.projects[1]?.standardizedFileURL.path == s.fx.repo.standardizedFileURL.path)
    }

    @Test func approvalBindsTheFileAndEveryGoalFile() async throws {
        let s = try await SeriesFixture()
        #expect(s.library.state(try s.library.load("s")) == .never)
        let hash = try s.library.approve("s")
        #expect(s.library.state(try s.library.load("s")) == .approved)
        #expect(s.library.approvedHash("s") == hash)

        try s.write("p1.md", goalText + "\n- Also this.\n")
        #expect(s.library.state(try s.library.load("s")) == .stale)
        _ = try s.library.approve("s")
        try s.write("series.md", "## 1\nproject: \(s.fx.repo.path)\ngoal: p1.md\nbase: main\n")
        #expect(s.library.state(try s.library.load("s")) == .stale)
    }

    @Test func whitespaceOnlyEditsKeepTheApproval() async throws {
        let s = try await SeriesFixture()
        _ = try s.library.approve("s")
        try s.write("p1.md", goalText.replacingOccurrences(of: "Add the thing.\n", with: "Add the thing.   \n") + "\n\n")
        #expect(s.library.state(try s.library.load("s")) == .approved)
    }

    @Test func aProblemInAnyStepIsReportedTogetherAndNothingIsApproved() async throws {
        let s = try await SeriesFixture(
            steps: "project: PROJECT\ngoal: p1.md\n## 2\nproject: /nonexistent/folder\ngoal: missing.md\n")
        do {
            _ = try s.library.approve("s")
            Issue.record("expected a refusal")
        } catch let error as SeriesError {
            let text = error.description
            #expect(text.contains("step 2: project /nonexistent/folder is not a folder"))
            #expect(text.contains("step 2: goal missing.md"))
        }
        #expect(s.library.approvedHash("s") == nil)
    }

    @Test func aStackedStepNeedsTheSameProjectAsItsParent() async throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".workbench"), withIntermediateDirectories: true)
        try "".write(to: other.appendingPathComponent(".workbench/config.toml"), atomically: true, encoding: .utf8)
        let s = try await SeriesFixture(
            steps: "project: PROJECT\ngoal: p1.md\n## 2\nproject: \(other.path)\ngoal: p1.md\nbase: after 1\n")
        do {
            _ = try s.library.load("s")
            Issue.record("expected a refusal")
        } catch let error as SeriesError {
            #expect(error.description.contains("needs the same project as step 1"))
        }
    }

    @Test func aGoalFileThatIsALinkOrNotAGoalIsRefused() async throws {
        let s = try await SeriesFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("goal-\(UUID().uuidString).md")
        try goalText.write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: s.directory.appendingPathComponent("p1.md"))
        try FileManager.default.createSymbolicLink(at: s.directory.appendingPathComponent("p1.md"), withDestinationURL: outside)
        do {
            _ = try s.library.load("s")
            Issue.record("expected a refusal")
        } catch let error as SeriesError { #expect(error.description.contains("not a regular file")) }

        try FileManager.default.removeItem(at: s.directory.appendingPathComponent("p1.md"))
        try s.write("p1.md", "just words, no front matter")
        do {
            _ = try s.library.load("s")
            Issue.record("expected a refusal")
        } catch let error as SeriesError { #expect(error.description.contains("goal p1.md")) }
    }

    @Test func aProjectThatIsNotAWorkbenchProjectIsRefused() async throws {
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        let s = try await SeriesFixture(steps: "project: \(bare.path)\ngoal: p1.md\n")
        do {
            _ = try s.library.load("s")
            Issue.record("expected a refusal")
        } catch let error as SeriesError { #expect(error.description.contains("is not a git checkout")) }
    }

    @Test func tildeIsExpandedAgainstTheGivenHome() async throws {
        let s = try await SeriesFixture(steps: "project: ~/repo\ngoal: p1.md\n")
        let library = SeriesLibrary(project: s.fx.project, home: s.fx.repo.deletingLastPathComponent())
        let name = s.fx.repo.lastPathComponent
        try s.write("series.md", "## 1\nproject: ~/\(name)\ngoal: p1.md\n")
        #expect(try library.load("s").projects[1]?.standardizedFileURL.path == s.fx.repo.standardizedFileURL.path)
    }

    @Test func noSuchSeriesIsNotFound() async throws {
        let s = try await SeriesFixture()
        #expect(throws: SeriesError.self) { try s.library.load("nope") }
    }

    @Test func aParseProblemAndAFileProblemInDifferentStepsAreReportedTogether() async throws {
        let s = try await SeriesFixture(
            steps: "project: PROJECT\ngoal: p1.md\ncolour: red\n## 2\nproject: /nonexistent/folder\ngoal: missing.md\n")
        do {
            _ = try s.library.load("s")
            Issue.record("expected a refusal")
        } catch let error as SeriesError {
            let text = error.description
            #expect(text.contains("unknown key 'colour'"))
            #expect(text.contains("step 2: project /nonexistent/folder is not a folder"))
            #expect(text.contains("step 2: goal missing.md"))
        }
    }

    @Test func anApprovalFileThatIsAFifoOrHugeReadsAsNotApprovedAndDoesNotHang() async throws {
        let s = try await SeriesFixture()
        let url = s.directory.appendingPathComponent("approval.json")
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(s.library.approvedHash("s") == nil)
        try FileManager.default.removeItem(at: url)
        try String(repeating: "x", count: 10_000).write(to: url, atomically: true, encoding: .utf8)
        #expect(s.library.approvedHash("s") == nil)
    }
}
