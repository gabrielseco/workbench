import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WorkbenchApp

/// The design's palette applies only while the chat feed preview is on (P22 rule 2); without it the app's own colours are unchanged.
@MainActor @Suite struct ThemeTests {
    private func hex(_ rgb: [Double]) -> String {
        "#" + rgb.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    /// The artboards' palette: the `TH` table of docs/design/chat-feed/*.dc.html (dark and light), and its `--side` and `--bg`.
    @Test func thePreviewPaletteIsTheArtboards() {
        struct Row {
            var token: Theme.Token
            var dark: String
            var light: String
        }
        let artboards = [
            Row(token: .blue, dark: "#5b9dff", light: "#1f5fd1"), Row(token: .green, dark: "#4cc38a", light: "#1b7f4e"),
            Row(token: .amber, dark: "#f0b04a", light: "#a35f00"), Row(token: .red, dark: "#f2685f", light: "#c8322a"),
            Row(token: .grey, dark: "#7e8695", light: "#667084"), Row(token: .rail, dark: "#1b1e24", light: "#eceef2"),
            Row(token: .canvas, dark: "#16191e", light: "#f4f5f8"),
        ]
        for row in artboards {
            #expect(hex(Theme.rgb(row.token, dark: true, preview: true)) == row.dark, "\(row.token) dark")
            #expect(hex(Theme.rgb(row.token, dark: false, preview: true)) == row.light, "\(row.token) light")
        }
    }

    /// What the app drew before the preview palette: these are the values that were in `Theme.swift`, and they stay for the old window.
    @Test func withoutThePreviewTheOldWindowKeepsItsColours() {
        struct Row {
            var token: Theme.Token
            var dark: [Double]
            var light: [Double]
        }
        let before = [
            Row(token: .blue, dark: [0.45, 0.62, 1.0], light: [0.12, 0.31, 0.86]),
            Row(token: .green, dark: [0.36, 0.80, 0.55], light: [0.07, 0.53, 0.31]),
            Row(token: .amber, dark: [0.98, 0.72, 0.28], light: [0.80, 0.50, 0.04]),
            Row(token: .red, dark: [1.0, 0.47, 0.45], light: [0.78, 0.16, 0.16]),
            Row(token: .grey, dark: [0.62, 0.64, 0.68], light: [0.56, 0.58, 0.62]),
            Row(token: .rail, dark: [0.14, 0.14, 0.14], light: [0.95, 0.95, 0.97]),
        ]
        for row in before {
            #expect(Theme.rgb(row.token, dark: true, preview: false) == row.dark, "\(row.token) dark")
            #expect(Theme.rgb(row.token, dark: false, preview: false) == row.light, "\(row.token) light")
        }
        #expect(Theme.rgb(.canvas, dark: true, preview: false).isEmpty, "the old window sets no content colour")
        #expect(Theme.rgb(.canvas, dark: false, preview: false).isEmpty)
    }

    @Test func theStoreFollowsThePreviewSwitchAndThemeReadsIt() async {
        let before = Theme.preview
        defer { Theme.preview = before }
        let preferences = MemoryPreferences()
        let store = ProjectStore(preferences: preferences)
        #expect(!Theme.preview && !store.chatFeedOn)
        await store.setChatFeed(true)
        #expect(Theme.preview)
        await store.setChatFeed(false)
        #expect(!Theme.preview)
        preferences.chatFeed = true
        _ = ProjectStore(preferences: preferences)
        #expect(Theme.preview, "a launch with the preview remembered starts with the design's palette")
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

    @Test func aDrawnColourSwitchesWithThePreviewAtOnce() {
        let before = Theme.preview
        defer { Theme.preview = before }
        Theme.preview = false
        #expect(drawn(Theme.blue, dark: true) == "#739eff" && drawn(Theme.rail, dark: true) == "#242424")
        Theme.preview = true
        #expect(drawn(Theme.blue, dark: true) == "#5b9dff" && drawn(Theme.rail, dark: true) == "#1b1e24")
        #expect(drawn(Theme.amber, dark: false) == "#a35f00" && drawn(Theme.canvas, dark: false) == "#f4f5f8")
        Theme.preview = false
        #expect(drawn(Theme.blue, dark: true) == "#739eff", "off again: the old window's colour")
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
        guard case .thread(let shown) = ProjectLoader.load(project: fixture.project, feed: true).screen else {
            Issue.record("no thread")
            return
        }
        #expect(FooterBar.limitText(.thread(shown), mode: .thread) == shown.turnTimeoutMin.map { "\($0) min per turn" })
        #expect(FooterBar.limitText(.thread(shown), mode: .tasks) == nil, "the thread is still loaded behind Tasks")
        var none = shown
        none.turnTimeoutMin = nil
        #expect(FooterBar.limitText(.thread(none), mode: .thread) == nil)
        #expect(FooterBar.limitText(.noThread, mode: .thread) == nil)
        #expect(StatePill.text(shown, short: true) == shown.stateHead)
        #expect(StatePill.text(shown, short: false) == shown.stateText)
    }
}
