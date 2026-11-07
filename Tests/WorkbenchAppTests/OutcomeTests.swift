import AppKit
import SwiftUI
import Testing

@testable import WorkbenchApp

/// How a result is told: each outcome has its own symbol, and the colour that means it (docs/DESIGN.md, the five meanings).
@MainActor @Suite struct OutcomeTests {
    /// A colour as the numbers it draws with in each appearance: `Theme`'s colours are dynamic, so two reads of one are not `==`.
    private func drawn(_ color: Color) -> [CGFloat] {
        [NSAppearance.Name.aqua, .darkAqua].flatMap { name -> [CGFloat] in
            var parts: [CGFloat] = []
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                let rgb = NSColor(color).usingColorSpace(.sRGB)
                parts = [rgb?.redComponent ?? -1, rgb?.greenComponent ?? -1, rgb?.blueComponent ?? -1]
            }
            return parts
        }
    }

    private func same(_ a: Color, _ b: Color) -> Bool { drawn(a) == drawn(b) }

    private let all: [Outcome] = [.passed, .failed, .warning, .pending, .skipped, .stopped, .unknown, .unavailable]

    @Test func everyOutcomeHasItsOwnSymbolAndItsOwnWord() {
        #expect(Set(all.map(\.symbol)).count == all.count, "no two outcomes share a symbol, so colour is never the only signal")
        #expect(Set(all.map(\.word)).count == all.count)
    }

    @Test func theStateColoursKeepTheirOneMeaning() {
        #expect(same(Outcome.passed.tint, Theme.green) && same(Outcome.failed.tint, Theme.red))
        #expect(same(Outcome.warning.tint, Theme.amber), "amber is what needs the person")
        #expect(same(Outcome.unavailable.tint, Theme.amber), "and what could not be read, which they may want to look at")
        #expect(same(Outcome.pending.tint, Theme.blue))
        #expect([Outcome.skipped, .stopped, .unknown].allSatisfy { same($0.tint, Theme.grey) })
        #expect(!same(Theme.green, Theme.red), "the helper tells two colours apart")
    }

    @Test func aTasksToneIsShownAsTheOutcomeOfTheSameMeaning() {
        #expect(TaskTone.done.outcome == .passed && TaskTone.broken.outcome == .failed)
        #expect(TaskTone.needsYou.outcome == .warning && TaskTone.idle.outcome == .skipped)
        #expect(TaskTone.working.outcome == nil, "working has a spinner of its own")
        #expect(TaskOutcomeStyle.symbol(.failed) == Outcome.failed.symbol, "the task outcomes take their symbols from here")
    }

    @Test func theMessageKindsAreToldApartBySymbolAndColour() {
        let kinds: [MessageKind] = [.error, .warning, .info, .success]
        #expect(Set(kinds.map(\.symbol)).count == 4)
        #expect(same(MessageKind.error.tint, Theme.red) && same(MessageKind.warning.tint, Theme.amber))
        #expect(same(MessageKind.success.tint, Theme.green) && same(MessageKind.info.tint, Theme.grey))
    }
}
