import Testing

@testable import WorkbenchApp

@Suite struct ProjectGlyphTests {
    @Test func theSamePathAlwaysGivesTheSamePicture() {
        let path = "/Users/a/rogal/workbench"
        #expect(ProjectGlyphSpec.of(path: path) == ProjectGlyphSpec.of(path: path))
    }

    @Test func theMarkIsMirroredAndNeitherBlankNorSolid() {
        for path in ["", "/a", "/b", "/Users/a/rogal/workbench", "/Users/a/remote/remote-flows"] {
            let marks = ProjectGlyphSpec.of(path: path).marks
            #expect(marks.count == 3 && marks.allSatisfy { $0.count == 3 && $0 == $0.reversed() })
            #expect((3...6).contains(marks.joined().filter { $0 }.count))
        }
    }

    @Test func projectsOnARailLookDifferent() {
        let paths = ["rf", "tr", "eb", "et", "wo", "a", "b", "c"].map { "/Users/g/\($0)" }
        #expect(Set(paths.map { "\(ProjectGlyphSpec.of(path: $0))" }).count == paths.count)
        #expect(Set(paths.map { ProjectGlyphSpec.of(path: $0).outline }).count >= 3)
    }
}
