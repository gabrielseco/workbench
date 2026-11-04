import SwiftUI

extension View {
    /// A picture cut to the thumbnail's rounded rectangle, with the hairline when it sits on a surface of its own colour.
    func thumbnail(outlined: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.thumbnail)
        return clipShape(shape).overlay { if outlined { shape.stroke(Theme.line) } }
    }
}
