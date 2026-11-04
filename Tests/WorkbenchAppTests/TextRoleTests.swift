import SwiftUI
import Testing

@testable import WorkbenchApp

/// A text role is one font and one colour; the roles that look alike (caption and mono) differ, and each reaches both Text and any view.
@MainActor @Suite struct TextRoleTests {
    @Test func eachRoleHasItsOwnFontAndColour() {
        #expect(TextRole.caption.font == .caption && TextRole.caption.color == .secondary)
        #expect(TextRole.detail.font == .callout && TextRole.detail.color == .secondary)
        #expect(TextRole.error.font == .callout && TextRole.warning.font == .callout)
        #expect(TextRole.mono.font == .system(.caption, design: .monospaced))
        #expect(TextRole.monoDetail.font == .system(.callout, design: .monospaced))
    }

    /// The colour of the boldest pixel of a big glyph drawn in the role, as (red, green, blue).
    private func ink(_ role: TextRole) -> [Int]? {
        let renderer = ImageRenderer(content: Text("\u{2588}\u{2588}\u{2588}").font(.system(size: 60)).role(role).padding(4))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        var best: [Int]?
        for start in stride(from: 0, to: bytes.count - 3, by: 4) where bytes[start + 3] > 240 {
            best = [Int(bytes[start]), Int(bytes[start + 1]), Int(bytes[start + 2])]
            break
        }
        return best
    }

    @Test func theErrorIsRedAndTheWarningIsAmber() throws {
        let error = try #require(ink(.error))
        let warning = try #require(ink(.warning))
        #expect(error[0] > error[1] + 60 && error[0] > error[2] + 60, "red: \(error)")
        #expect(warning[0] > warning[2] + 60 && warning[1] > warning[2] + 30, "amber: \(warning)")
    }

    @Test func aRoleKeepsATextATextAndOtherViewsGetTheSame() {
        let text: Text = Text("x").role(.error)
        let label = String(describing: Label("x", systemImage: "bell").textRole(.error))
        #expect(String(describing: text).contains("Text"))
        #expect(label.contains("font") || label.contains("Font"))
    }
}
