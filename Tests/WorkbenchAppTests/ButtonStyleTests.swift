import SwiftUI
import Testing

@testable import WorkbenchApp

/// The artboards' buttons and the chip layout (design parity 9). The style modifiers are the system's with the preview off.
@MainActor @Suite(.serialized) struct ButtonStyleTests {
    /// `ImageRenderer` draws a native button as a placeholder, so the look is checked in the app's own shots; what is checked here is the
    /// choice each modifier makes, which is what keeps the old window unchanged.
    @Test func thePreviewChoosesOurStylesAndWithoutItTheSystemOnes() {
        #expect(ButtonChoice.pick(preview: true) == .ours)
        #expect(ButtonChoice.pick(preview: false) == .system, "preview off: the old window's buttons are the system's")
    }

    @Test func theModifiersReadThePreviewFlagAtDrawTime() {
        let before = Theme.preview
        defer { Theme.preview = before }
        for flag in [true, false] {
            Theme.preview = flag
            #expect(ButtonChoice.pick(preview: Theme.preview) == (flag ? .ours : .system))
        }
    }

    // MARK: Chips

    @Test func chipsFlowLeftToRightAndWrapWhenTheWidthRunsOut() {
        let sizes = [CGSize(width: 60, height: 20), CGSize(width: 60, height: 20), CGSize(width: 60, height: 20)]
        let one = FlowLayout.arrange(sizes: sizes, width: 200, spacing: 5)
        #expect(one.origins == [CGPoint(x: 0, y: 0), CGPoint(x: 65, y: 0), CGPoint(x: 130, y: 0)] && one.size.height == 20)
        let wrapped = FlowLayout.arrange(sizes: sizes, width: 130, spacing: 5)
        #expect(wrapped.origins[2] == CGPoint(x: 0, y: 25), "the third does not fit and starts a new line")
        #expect(wrapped.size == CGSize(width: 125, height: 45))
        #expect(FlowLayout.arrange(sizes: [], width: 100, spacing: 5).size == .zero)
        let wide = FlowLayout.arrange(sizes: [CGSize(width: 300, height: 20)], width: 100, spacing: 5)
        #expect(wide.origins == [.zero], "a chip wider than the row still goes somewhere, alone")
    }
}
