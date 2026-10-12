import Testing
@testable import WorkbenchCore

@Suite struct WorkbenchTests {
    @Test func versionIsSemver() {
        let parts = Workbench.version.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }
}
