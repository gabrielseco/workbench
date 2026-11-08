import Foundation
import Testing

@testable import WorkbenchApp

@Suite struct RailProjectsTests {
    @Test func theRailIsSeededFromTheRecentsOldestFirstSoTilesDoNotJump() {
        #expect(RailProjects.seed(fromRecents: ["/c", "/b", "/a"]) == ["/a", "/b", "/c"])
        #expect(RailProjects.seed(fromRecents: []).isEmpty)
    }

    @Test func aProjectIsAddedOnceAtTheEndAndKeepsItsPlace() {
        let list = ["/a", "/b"]
        #expect(RailProjects.adding("/c", to: list) == ["/a", "/b", "/c"])
        #expect(RailProjects.adding("/a", to: list) == list, "already there: it keeps its place")
    }

    @Test func theRailHoldsAtMostItsLimit() {
        let full = (0..<RailProjects.limit).map { "/p\($0)" }
        #expect(RailProjects.adding("/more", to: full) == full, "the newest is not added past the limit")
    }

    @Test func removingAndMovingKeepTheRestInOrder() {
        let list = ["/a", "/b", "/c"]
        #expect(RailProjects.removing("/b", from: list) == ["/a", "/c"])
        #expect(RailProjects.removing("/x", from: list) == list)
        #expect(RailProjects.moving("/c", by: -1, in: list) == ["/a", "/c", "/b"])
        #expect(RailProjects.moving("/a", by: -1, in: list) == list, "the first cannot go earlier")
        #expect(RailProjects.moving("/c", by: 1, in: list) == list, "the last cannot go later")
        #expect(RailProjects.moving("/x", by: 1, in: list) == list)
    }

    @Test func theInitialsAreTwoLettersFromTheNameOrItsFirstTwoWords() {
        #expect(RailProjects.initials(of: "project") == "pr")
        #expect(RailProjects.initials(of: "expenses-backend") == "eb")
        #expect(RailProjects.initials(of: "remote_flows") == "rf")
        #expect(RailProjects.initials(of: "a") == "a")
        #expect(RailProjects.initials(of: "App") == "ap")
        #expect(RailProjects.initials(of: "2fa-service") == "2s")
    }

    @Test func twoProjectsWithOneFolderNameAreToldApartByTheirParent() {
        let tiles = RailProjects.tiles(["/work/api", "/home/api", "/work/web"], unavailable: { _ in nil })
        #expect(tiles.map(\.name) == ["api (work)", "api (home)", "web"])
        #expect(tiles.map(\.initials) == ["ap", "ap", "we"])
    }

    @Test func aProjectThatCannotBeOpenedSaysWhyOnItsTile() {
        let tiles = RailProjects.tiles(["/a", "/gone"], unavailable: { $0 == "/gone" ? "The folder is gone." : nil })
        #expect(tiles.map(\.unavailable) == [nil, "The folder is gone."])
    }

    @Test func theBadgeIsTheMostUrgentThingTheProjectHolds() {
        #expect(RailBadge.from(needsYou: 4, failed: 1, running: true) == .failed(1), "failed over needs you")
        #expect(RailBadge.from(needsYou: 4, failed: 0, running: true) == .needsYou(4), "needs you over running")
        #expect(RailBadge.from(needsYou: 0, failed: 0, running: true) == .running)
        #expect(RailBadge.from(needsYou: 0, failed: 0, running: false) == .none)
    }

    @Test func theTileIsNamedWithItsBadgeForAssistiveTechnology() {
        #expect(RailBadge.needsYou(4).label(for: "project") == "project, 4 need you")
        #expect(RailBadge.failed(1).label(for: "api") == "api, 1 failed")
        #expect(RailBadge.running.label(for: "mobile") == "mobile, running")
        #expect(RailBadge.none.label(for: "docs") == "docs")
    }
}
