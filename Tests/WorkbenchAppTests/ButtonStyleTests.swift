import SwiftUI
import Testing

@testable import WorkbenchApp

/// The artboards' buttons and the chip layout (design parity 9).
@MainActor @Suite(.serialized) struct ButtonStyleTests {
    /// What each modifier actually applies, read from the value of the view it returns: a view's description names the style it carries
    /// (`style: <Type>`). `ImageRenderer` draws a native button as a placeholder, so the look is checked in the app's own shots.
    @Test func theModifiersApplyOurStyles() {
        let primary = String(describing: Button("x") {}.primaryButton())
        let plain = String(describing: Button("x") {}.plainButton())
        let bare = String(describing: Toggle("x", isOn: .constant(true)))
        #expect(primary.contains("style: WorkbenchApp.PrimaryButtonStyle"))
        #expect(plain.contains("style: WorkbenchApp.PlainButtonStyle"))
        #expect(bare != String(describing: Toggle("x", isOn: .constant(true)).switchTint()), "the switch is tinted")
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
        let sizes2 = [CGSize(width: 300, height: 20), CGSize(width: 40, height: 20)]
        let wide = FlowLayout.arrange(sizes: sizes2, width: 100, spacing: 5)
        #expect(wide.origins == [.zero, CGPoint(x: 0, y: 25)], "a chip wider than the row is alone on it")
        #expect(wide.size.width <= 100, "and no wider than the row: nothing leaves the panel")
    }
}
