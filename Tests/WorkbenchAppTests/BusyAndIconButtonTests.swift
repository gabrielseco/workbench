import SwiftUI
import Testing

@testable import WorkbenchApp

/// The spinner, the busy line and the icon-only button: what they are made of is decided here, and what a view cannot leave out.
@MainActor @Suite struct BusyAndIconButtonTests {
    @Test func aBusyLineWithAStopHasTheStopsNameAndRunsItsAction() {
        var stopped = 0
        let stop = BusyLine.Stop(title: "Stop", label: "Stop the reply") { stopped += 1 }
        let line = BusyLine("Replying…", tone: .working, stop: stop, spread: true)
        #expect(line.text == "Replying…" && line.tone == .working && line.spread && !line.stacked)
        line.stop?.perform()
        #expect(stopped == 1)
        #expect(line.stop?.label == "Stop the reply" && line.stop?.disabled == false)
        #expect(BusyLine("x").stop == nil && BusyLine("x").tone == .quiet, "the window's own busy line is quiet and has no stop")
    }

    @Test func theCloseAndBadgeButtonsAreCrossesWithANameAndATooltip() {
        let close = IconButton.close("Close the thing") {}
        #expect(close.symbol == "xmark" && close.label == "Close the thing" && close.help == nil)
        let badge = IconButton.badge("Remove screenshot 1", help: "Remove screenshot") {}
        #expect(badge.symbol == "xmark.circle.fill" && badge.help == "Remove screenshot")
        let raised = IconButton.raised("plus", "New goal", help: "New goal…", size: .small) {}
        if case .raised(let size) = raised.look { #expect(size == .small) } else { Issue.record("a raised button looks raised") }
    }

    /// The bytes of a view drawn at 80 × 40 points on white, to tell a view that draws something from one that draws nothing.
    private func pixels(_ view: some View) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: 80, height: 40).background(Color.white))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    @Test func theToolbarPillAndTheCloseButtonDrawSomethingAndNotNothing() throws {
        let blank = try #require(pixels(Color.clear))
        #expect(try #require(pixels(ToolbarPillButton(selected: false, action: {}, label: { Text("project") }))) != blank)
        #expect(try #require(pixels(IconButton.close("Close") {})) != blank)
        #expect(try #require(pixels(IconButton.raised("plus", "Add") {})) != blank)
        #expect(
            try #require(pixels(ToolbarPillButton(selected: true, action: {}, label: { Text("project") })))
                != (try #require(pixels(ToolbarPillButton(selected: false, action: {}, label: { Text("project") })))),
            "an open pill is drawn darker than a closed one")
    }
}
