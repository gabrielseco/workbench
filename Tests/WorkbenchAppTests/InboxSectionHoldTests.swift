import Foundation
import Testing

@testable import WorkbenchApp

/// A row changes section only once the new one has held, so a fix loop does not shuffle the list.
@Suite struct InboxSectionHoldTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func aRowSeenForTheFirstTimeIsDrawnWhereItBelongs() {
        var hold = InboxSectionHold()
        #expect(hold.update(target: ["a": .working, "b": .needsYou], now: t0) == nil)
        #expect(hold.shown == ["a": .working, "b": .needsYou])
    }

    @Test func aRowMovesOnlyAfterItsNewSectionHeldForTheDelay() {
        var hold = InboxSectionHold()
        hold.update(target: ["a": .working], now: t0)
        let due = hold.update(target: ["a": .needsYou], now: at(1))
        #expect(due == at(1 + InboxSectionHold.delay))
        #expect(hold.shown["a"] == .working, "it stays until the delay is up")
        #expect(hold.update(target: ["a": .needsYou], now: at(1 + InboxSectionHold.delay)) == nil)
        #expect(hold.shown["a"] == .needsYou)
    }

    @Test func aFlickerBackToTheDrawnSectionNeverMovesTheRow() {
        var hold = InboxSectionHold()
        hold.update(target: ["a": .working], now: t0)
        hold.update(target: ["a": .needsYou], now: at(1))
        hold.update(target: ["a": .working], now: at(2))
        hold.update(target: ["a": .needsYou], now: at(3))
        // The clock restarted at 3: 3 s after the first flip is not 3 s of holding.
        hold.update(target: ["a": .needsYou], now: at(1 + InboxSectionHold.delay))
        #expect(hold.shown["a"] == .working)
    }

    @Test func aNewDestinationRestartsTheDelay() {
        var hold = InboxSectionHold()
        hold.update(target: ["a": .waiting], now: t0)
        hold.update(target: ["a": .working], now: at(0))
        hold.update(target: ["a": .needsYou], now: at(2.9))
        hold.update(target: ["a": .needsYou], now: at(InboxSectionHold.delay))
        #expect(hold.shown["a"] == .waiting, "needs you has held for 0.1 s, not 3")
        hold.update(target: ["a": .needsYou], now: at(2.9 + InboxSectionHold.delay))
        #expect(hold.shown["a"] == .needsYou)
    }

    @Test func aFrozenRailKeepsRowsPutButLetsNewOnesAndGoneOnesThrough() {
        var hold = InboxSectionHold()
        hold.update(target: ["a": .working, "gone": .waiting], now: t0)
        let due = hold.update(target: ["a": .needsYou, "new": .waiting], now: at(60), frozen: true)
        #expect(due == nil, "the pointer leaving asks again")
        #expect(hold.shown == ["a": .working, "new": .waiting])
        hold.update(target: ["a": .needsYou, "new": .waiting], now: at(61))
        hold.update(target: ["a": .needsYou, "new": .waiting], now: at(61 + InboxSectionHold.delay))
        #expect(hold.shown["a"] == .needsYou)
    }

    @Test func theModelDrawsAHeldRowInItsHeldSection() {
        let rows = [
            ThreadRow(id: "a", title: "a", mark: .needsYou, line: "x"), ThreadRow(id: "b", title: "b", mark: .working, line: "x"),
        ]
        let listing = ThreadListing(rows: rows)
        let held = ["thread-a": InboxSection.working]
        let model = InboxModel.derive(listing: listing, tasks: nil, held: held)
        #expect(model.working.map(\.key) == ["a", "b"], "a still waits to move; its row is the live one")
        #expect(model.needsYou.isEmpty)
        #expect(InboxModel.sections(listing: listing, tasks: nil) == ["thread-a": .needsYou, "thread-b": .working])
    }
}
