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

    /// The alpha of the centre of a view drawn at 40 × 40 points, so a view that draws nothing is told from one that draws.
    private func draws(_ view: some View) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: 40, height: 40).background(Color.white))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return false }
        return image.width == 40 && image.height == 40
    }

    @Test func theToolbarPillAndTheCloseButtonDraw() {
        #expect(draws(ToolbarPillButton(selected: false, action: {}, label: { Text("project") })))
        #expect(draws(IconButton.close("Close") {}))
        #expect(draws(Spinner(.mini, inColumn: true)))
    }
}
