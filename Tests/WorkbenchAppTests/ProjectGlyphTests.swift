import Testing

@testable import WorkbenchApp

@Suite struct ProjectGlyphTests {
    @Test func theSamePathAlwaysGivesTheSamePicture() {
        let path = "/Users/a/rogal/workbench"
        #expect(ProjectGlyphCells.cells(for: path) == ProjectGlyphCells.cells(for: path))
    }

    @Test func thePictureIsMirroredAndNeitherBlankNorSolid() {
        for path in ["", "/a", "/b", "/Users/a/rogal/workbench", "/Users/a/remote/remote-flows"] {
            let cells = ProjectGlyphCells.cells(for: path)
            #expect(cells.count == 5 && cells.allSatisfy { $0.count == 5 && $0 == $0.reversed() })
            #expect((8...16).contains(cells.joined().filter { $0 }.count))
        }
    }

    @Test func differentProjectsGetDifferentPictures() {
        let paths = ["rf", "tr", "eb", "et", "wo", "a", "b", "c", "d", "e"].map { "/Users/g/\($0)" }
        #expect(Set(paths.map { ProjectGlyphCells.cells(for: $0).flatMap { $0 } }).count == paths.count)
    }
}
