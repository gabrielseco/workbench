import SwiftUI

/// How tall the body of a modal is when it scrolls: named steps, so two modals that hold the same kind of thing are the same height. A step the
/// scale lacks is a new case, decided once.
enum ModalBodyHeight {
    /// A short list (what discarding would remove).
    case short
    /// A page of findings.
    case medium
    /// A diff.
    case tall
    /// A whole screen's worth (the review, Run settings).
    case page

    var points: CGFloat {
        switch self {
        case .short: 200
        case .medium: 280
        case .tall: 360
        case .page: 440
        }
    }
}

extension View {
    /// This content at the height of a modal's body.
    func modalBody(_ height: ModalBodyHeight) -> some View { frame(height: height.points) }
}

/// Text that is read, not edited, in a box that scrolls: monospaced, selectable, at the left. A diff, a plan, what Codex found.
struct CodeBox: View {
    var text: String
    var height: ModalBodyHeight

    init(_ text: String, height: ModalBodyHeight) { (self.text, self.height) = (text, height) }

    var body: some View {
        ScrollView {
            Text(text).textStyle(.monoCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .modalBody(height)
    }
}
