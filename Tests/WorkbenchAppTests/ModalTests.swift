import AppKit
import SwiftUI
import Testing

@testable import WorkbenchApp

/// Every modal is `.modal`: its steps, its labels (which `scripts/verify-app.sh` presses by) and what it draws are decided here.
@MainActor @Suite struct ModalTests {
    @Test func sizesAreDistinctAndGrow() {
        #expect(ModalSize.small.width == 420 && ModalSize.medium.width == 560 && ModalSize.large.width == 760)
        #expect(ModalSize.fitting.width == nil, "a picture sets the width of its own card")
    }

    @Test func theCloseControlKeepsTheLabelsTheCardsHadBefore() {
        #expect(ModalText.closeLabel("Agents") == "Close the agents panel")
        #expect(ModalText.closeLabel("Projects") == "Close the projects panel")
        #expect(ModalText.closeLabel("PR review") == "Close the PR review panel", "an acronym keeps its capitals")
        #expect(ModalText.closeLabel("Merge PR #482") == "Close the merge PR #482 panel")
    }

    @Test func aCardUnderTheToolbarSitsAtTheLeadingEdgeAndACenteredOneInTheMiddle() {
        #expect(ModalPlacement.topLeading.alignment == .topLeading && ModalPlacement.centered.alignment == .center)
    }

    /// The red channel of the window's corner pixel, with the modal shown or not; nil if it could not be drawn.
    private func corner(presented: Bool) -> Double? {
        let view = Color.white.frame(width: 700, height: 500)
            .modal("Test", isPresented: .constant(presented), size: .small) { Text("body") }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        return Double(bytes[2]) / 255
    }

    @Test func aShownModalDrawsItsVeilOverTheWindow() throws {
        let open = try #require(corner(presented: true))
        let closed = try #require(corner(presented: false))
        #expect(closed > 0.95, "nothing over the window while it is not shown")
        #expect(open < closed, "the veil darkens what is behind the card")
    }

    private func press(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: keyCode)
        if let event { NSApp.sendEvent(event) }
    }

    @Test func escClosesOnlyTheNewestModalAndTheNextEscTheOneUnderIt() {
        _ = NSApplication.shared
        var closed: [String] = []
        let review = EscapeKey(), diff = EscapeKey()
        review.start { closed.append("review") }
        diff.start { closed.append("diff") }
        press(keyCode: 53)
        #expect(closed == ["diff"], "the diff over the review hears it first")
        diff.stop()
        press(keyCode: 53)
        #expect(closed == ["diff", "review"], "then the review")
        review.stop()
        press(keyCode: 53)
        #expect(closed == ["diff", "review"], "nothing is listening once both are gone")
    }

    @Test func onlyAPlainEscIsTaken() {
        _ = NSApplication.shared
        var closed = 0
        let key = EscapeKey()
        key.start { closed += 1 }
        defer { key.stop() }
        press(keyCode: 36)
        press(keyCode: 53, modifiers: .command)
        #expect(closed == 0, "another key, or ⌘⎋, is left to whoever wants it")
        press(keyCode: 53)
        #expect(closed == 1)
    }
}
