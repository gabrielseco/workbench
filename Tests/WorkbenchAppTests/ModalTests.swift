import SwiftUI
import Testing

@testable import WorkbenchApp

/// Every modal is `.modal`: its steps, its labels (which `scripts/verify-app.sh` presses by) and what it draws are decided here.
@MainActor @Suite struct ModalTests {
    @Test func sizesAreDistinctAndGrow() {
        #expect(ModalSize.small.width == 420 && ModalSize.medium.width == 560)
    }

    @Test func theCloseControlKeepsTheLabelsTheCardsHadBefore() {
        #expect(ModalText.closeLabel("Agents") == "Close the agents panel")
        #expect(ModalText.closeLabel("Projects") == "Close the projects panel")
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
}
