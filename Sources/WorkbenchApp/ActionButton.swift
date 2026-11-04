import SwiftUI

/// A button for one of the feed's actions: its title, whether it is enabled and what it says on hover come from the action, and its look from
/// a `ButtonKind` and `ButtonSize`, so every action button is wired and drawn the same way.
struct ActionButton: View {
    var action: FeedAction
    var kind: ButtonKind = .plain
    var size: ButtonSize = .regular
    /// Words for the button where the action's own title is longer than the place has room for.
    var title: String?
    var symbol: String?
    var perform: (FeedAction) -> Void

    /// What the button says and what hovering it says: the override and the action's help, each falling back to the action's title.
    var label: String { title ?? action.title }
    var hover: String { action.help ?? action.title }

    var body: some View {
        Button { perform(action) } label: {
            if let symbol { Label(label, systemImage: symbol) } else { Text(label) }
        }
        .buttonStyle(WorkbenchButtonStyle(kind: kind, size: size))
        .disabled(!action.enabled)
        .help(hover)
    }
}
