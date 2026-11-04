import SwiftUI
import Testing

@testable import WorkbenchApp

/// The symbol column, the gap and the baseline are the row's, not its callers'.
@MainActor @Suite(.serialized) struct IconRowTests {
    private func size(_ view: some View) -> CGSize? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage.map { CGSize(width: $0.width, height: $0.height) }
    }

    @Test func theSymbolHasAFixedColumnAndAGapBeforeTheContent() throws {
        let narrow = try #require(size(IconRow(symbol: "circle", tint: .red) { Color.clear.frame(width: 10, height: 10) }))
        let wide = try #require(
            size(IconRow(symbol: "wrench.and.screwdriver", tint: .red) { Color.clear.frame(width: 10, height: 10) }))
        #expect(narrow.width == 34 && wide.width == 34, "16 for the symbol, 8 gap, 10 content: \(narrow.width), \(wide.width)")
    }

    @Test func theContentSitsAfterTheSymbolWhateverItIs() throws {
        let one = try #require(size(IconRow(symbol: "circle", tint: .red) { Color.clear.frame(width: 50, height: 10) }))
        let two = try #require(size(IconRow(symbol: "circle", tint: .red) { Color.clear.frame(width: 80, height: 10) }))
        #expect(two.width - one.width == 30)
    }
}
