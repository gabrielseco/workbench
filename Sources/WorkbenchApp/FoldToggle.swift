import SwiftUI

/// The line that opens or closes a folded section (`Show 9 finished threads`, `Hide finished threads`): grey, a chevron before the words,
/// pointing right while the section is closed and down while it is open, as the design draws it.
struct FoldToggle: View {
    var title: String
    var expanded: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").textStyle(.captionBold, .secondary)
                Text(title).textStyle(.callout, .secondary)
            }
            .padding(.horizontal, Space.s).padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).help(help)
    }
}
