import SwiftUI
import Testing

@testable import WorkbenchApp

/// The dots, the avatar, the code box, the empty note and the sizes they stand on: what is named here is not a number in a view.
@MainActor @Suite struct MarksAndBoxesTests {
    private func pixels(_ view: some View, width: CGFloat = 200, height: CGFloat = 80) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Color.white))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    @Test func theModalBodyHeightsAreFourDistinctStepsThatGrow() {
        let steps: [ModalBodyHeight] = [.short, .medium, .tall, .page]
        #expect(steps.map(\.points) == steps.map(\.points).sorted() && Set(steps.map(\.points)).count == 4)
        // The card adds its padding and its header row, and the window leaves the toolbar and the footer: at 600 pt the tallest still fits.
        let chrome = 2 * Space.l + 40
        #expect(ModalBodyHeight.page.points + chrome < 600 - 2 * Space.xl, "the tallest body fits the minimum window")
    }

    @Test func theSymbolColumnsAndTheDotsHaveTheirSizes() {
        #expect(SymbolColumn.regular.width == 16 && SymbolColumn.narrow.width == 14)
        #expect(DotSize.regular.side < DotSize.large.side && DotSize.regular.halo > DotSize.large.side)
        #expect(AgentAvatar.side == 22)
    }

    @Test func eachMarkDrawsSomethingAndAFilledDotDiffersFromARing() throws {
        let blank = try #require(pixels(Color.clear))
        let ring = try #require(pixels(StatusDot(Theme.amber)))
        let filled = try #require(pixels(StatusDot(Theme.amber, filled: true)))
        let halo = try #require(pixels(StatusDot(Theme.amber, filled: true, halo: true)))
        #expect(ring != blank && filled != blank && avatarDraws(blank))
        #expect(Set([ring, filled, halo]).count == 3, "a ring, a disc and a disc with a wash are three marks")
    }

    private func avatarDraws(_ blank: Data) -> Bool { pixels(AgentAvatar()) != blank }

    /// A scroll view is not drawn by an image renderer, so the code box's look is seen live.
    @Test func aCodeBoxKeepsItsTextAndItsHeightAndAnEmptyNoteDrawsItsSizes() throws {
        let box = CodeBox("let x = 1", height: .tall)
        #expect(box.text == "let x = 1" && box.height == .tall)
        let blank = try #require(pixels(Color.clear, width: 300, height: 200))
        let small = try #require(pixels(EmptyNote("No threads yet.", size: .small), width: 300, height: 200))
        let large = try #require(pixels(EmptyNote("No threads yet.", size: .large), width: 300, height: 200))
        #expect(small != blank && small != large, "the sizes are told apart")
    }
}
