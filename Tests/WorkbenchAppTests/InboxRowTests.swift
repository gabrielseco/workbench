import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptInboxFixtures: [AppFixture] = []

/// What an inbox row carries beyond the thread list's: what the thread cost, and whether it is over.
@MainActor @Suite struct InboxRowTests {
    @Test func aRowSaysWhatItCostAndWhetherItIsOver() async throws {
        let fixture = try await AppFixture()
        keptInboxFixtures.append(fixture)
        try await fixture.addThread("draft", title: "Draft")
        try await fixture.addThread("shipped", approved: true, title: "Accepted, not shipped")
        try fixture.turn("shipped", 1)
        try fixture.decide("shipped", "accepted")
        try await fixture.addThread("thrown", approved: true, title: "Thrown away")
        try fixture.turn("thrown", 1)
        try fixture.decide("thrown", "discarded")
        let listing = ThreadListLoader.load(project: fixture.project, cache: .init())
        let byID = Dictionary(uniqueKeysWithValues: listing.rows.map { ($0.id, $0) })
        #expect(byID["draft"]?.spend == nil && byID["draft"]?.finished == false, "no turn yet: no cost, and not over")
        #expect(byID["shipped"]?.spend?.hasPrefix("$") == true, "a cost is shown as money")
        #expect(byID["shipped"]?.finished == false, "accepted and not shipped still waits for a person to ship it")
        #expect(byID["thrown"]?.finished == true, "thrown away is over")
        #expect(InboxSection.of(byID["thrown"]!) == .done && InboxSection.of(byID["shipped"]!) == .waiting)
    }
}
