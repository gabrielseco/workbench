import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WorkbenchApp

/// The design's palette (docs/design/chat-feed) is the app's only palette.
@MainActor @Suite struct ThemeTests {
    private func hex(_ rgb: [Double]) -> String {
        "#" + rgb.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    /// The artboards' palette: the `TH` table of docs/design/chat-feed/*.dc.html (dark and light), and its `--side` and `--bg`.
    @Test func thePaletteIsTheArtboards() {
        struct Row {
            var token: Theme.Token
            var dark: String
            var light: String
        }
        let artboards = [
            Row(token: .blue, dark: "#5b9dff", light: "#1f5fd1"), Row(token: .green, dark: "#4cc38a", light: "#1b7f4e"),
            Row(token: .amber, dark: "#f0b04a", light: "#a35f00"), Row(token: .red, dark: "#f2685f", light: "#c8322a"),
            Row(token: .grey, dark: "#7e8695", light: "#667084"), Row(token: .rail, dark: "#1b1e24", light: "#eceef2"),
            Row(token: .canvas, dark: "#16191e", light: "#f4f5f8"), Row(token: .raised, dark: "#2a2f39", light: "#e1e5ec"),
            Row(token: .panel, dark: "#21252d", light: "#ffffff"), Row(token: .line, dark: "#323844", light: "#d3d8e0"),
            Row(token: .fg2, dark: "#b0b7c4", light: "#454d5d"), Row(token: .fg3, dark: "#919aaa", light: "#5d667a"),
            Row(token: .inv, dark: "#eef0f4", light: "#1b1f27"), Row(token: .invfg, dark: "#14171c", light: "#f4f5f8"),
        ]
        for row in artboards {
            #expect(hex(Theme.rgb(row.token, dark: true)) == row.dark, "\(row.token) dark")
            #expect(hex(Theme.rgb(row.token, dark: false)) == row.light, "\(row.token) light")
        }
    }

    /// The primary button's label sits on its fill: the pair is readable (WCAG contrast at least 7:1) in both appearances.
    @Test func theInversePairIsReadableInBothAppearances() {
        func luminance(_ rgb: [Double]) -> Double {
            let lin = rgb.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
        }
        for dark in [true, false] {
            let a = luminance(Theme.rgb(.inv, dark: dark))
            let b = luminance(Theme.rgb(.invfg, dark: dark))
            let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
            #expect(ratio >= 7, "\(dark ? "dark" : "light") contrast \(ratio)")
        }
    }

    /// The colour a view actually draws, resolved for an appearance: this is what the toolbar, rail and rows get from `Theme.blue`.
    private func drawn(_ colour: Color, dark: Bool) -> String {
        var result = ""
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let rgb = NSColor(colour).usingColorSpace(.sRGB)!
            result = hex([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Double($0) })
        }
        return result
    }

    @Test func aDrawnColourIsTheDesignsInEachAppearance() {
        #expect(drawn(Theme.blue, dark: true) == "#5b9dff" && drawn(Theme.rail, dark: true) == "#1b1e24")
        #expect(drawn(Theme.amber, dark: false) == "#a35f00" && drawn(Theme.canvas, dark: false) == "#f4f5f8")
    }

    // MARK: Chrome

    @Test func theStatePillSaysTheHeadAndTheRowKeepsTheReason() {
        #expect(ThreadSnapshot.head(of: "Needs you · Review · turn 1 done") == "Needs you")
        #expect(ThreadSnapshot.head(of: "Draft · not approved") == "Draft")
        #expect(ThreadSnapshot.head(of: "Chat · replying") == "Chat")
        #expect(ThreadSnapshot.head(of: "Working") == "Working")
        #expect(ThreadSnapshot.head(of: "Accepted") == "Accepted")
        #expect(ThreadSnapshot.head(of: "") == "")
    }

    @Test func theFooterSaysThePerTurnLimitOnlyForAThreadThatHasOne() async throws {
        let fixture = try await AppFixture()
        try await fixture.addThread("t1", approved: true)
        guard case .thread(let shown) = ProjectLoader.load(project: fixture.project).screen else {
            Issue.record("no thread")
            return
        }
        #expect(FooterBar.limitText(.thread(shown), mode: .thread) == shown.turnTimeoutMin.map { "\($0) min per turn" })
        #expect(FooterBar.limitText(.thread(shown), mode: .tasks) == nil, "the thread is still loaded behind Tasks")
        var none = shown
        none.turnTimeoutMin = nil
        #expect(FooterBar.limitText(.thread(none), mode: .thread) == nil)
        #expect(FooterBar.limitText(.noThread, mode: .thread) == nil)
        #expect(StatePill.text(shown) == shown.stateHead)
    }
}
