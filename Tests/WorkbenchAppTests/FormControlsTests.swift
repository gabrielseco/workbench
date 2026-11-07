import SwiftUI
import Testing

@testable import WorkbenchApp

/// The text input, the switch row and the card title: what each is made of, and that each draws something.
@MainActor @Suite struct FormControlsTests {
    private func pixels(_ view: some View, width: CGFloat = 240, height: CGFloat = 60) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Color.white))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    @Test func aTextInputKeepsItsLookItsStyleItsNameAndItsKeys() {
        let input = TextInput(
            "Find", text: .constant("x"), look: .filled, style: .callout, icon: "magnifyingglass", dense: true, label: "Search",
            keys: { _ in .handled })
        #expect(input.placeholder == "Find" && input.icon == "magnifyingglass" && input.dense && input.label == "Search")
        if case .filled = input.look {} else { Issue.record("the look is filled") }
        #expect(input.keys != nil)
        #expect(TextInput("x", text: .constant("")).keys == nil, "no key handling unless asked for")
    }

    @Test func eachLookOfATextInputDrawsSomethingAndTheFilledWellDiffersFromTheBareField() throws {
        let blank = try #require(pixels(Color.clear))
        let bare = try #require(pixels(TextInput("Name", text: .constant("text"), look: .bare)))
        let bordered = try #require(pixels(TextInput("Name", text: .constant("text"), look: .bordered)))
        let filled = try #require(pixels(TextInput("Name", text: .constant("text"), look: .filled, icon: "magnifyingglass")))
        #expect(bare != blank && bordered != blank && filled != blank)
        #expect(Set([bare, bordered, filled]).count == 3, "the three looks are three looks")
    }

    @Test func aSwitchRowSaysItsTitleAndEachOfItsLines() throws {
        let row = SwitchRow("Judge", details: ["Checks the work.", "From the config."], isOn: .constant(true))
        #expect(row.title == "Judge" && row.details.count == 2 && row.enabled)
        let blank = try #require(pixels(Color.clear))
        let on = try #require(pixels(SwitchRow("Judge", details: ["Checks the work."], isOn: .constant(true))))
        #expect(on != blank, "the title and the line are drawn (the native switch itself is not, in an image renderer)")
        let bare = try #require(pixels(SwitchRow("Judge", details: [], isOn: .constant(true))))
        #expect(bare != on, "a line less is a different row")
    }

    @Test func aCardTitleHasItsLabelItsHeadingAndTheSentenceUnderIt() throws {
        let plain = try #require(pixels(CardTitle("NEXT", title: "Accept the work")))
        let withDetail = try #require(pixels(CardTitle("NEXT", title: "Accept the work", detail: "turn 1 done")))
        let blank = try #require(pixels(Color.clear))
        #expect(plain != withDetail && plain != blank)
    }
}
