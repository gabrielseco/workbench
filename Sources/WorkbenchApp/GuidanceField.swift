import SwiftUI

/// The text box under the decision card while a thread is in review: write what should change and the card's primary becomes
/// "Send to agent". Empty, it is just there, so asking for more is no extra step. The text is the store's, per thread.
struct GuidanceField: View {
    var store: ProjectStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("GUIDANCE")
            PlaceholderTextEditor(
                text: Binding(get: { store.guidanceNote }, set: { store.guidanceNote = $0 }),
                placeholder: "Anything the agent should change? Say what is wrong and what you expect instead.", style: .body,
                accessibilityLabel: "Guidance for the agent", focus: $focused
            )
            .frame(minHeight: 72, maxHeight: 160)
            Text("The next turn also gets the failed check's output.").role(.caption)
        }
        .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task(id: store.guidanceFocus) {
            guard store.guidanceFocus > store.guidanceFocusServed else { return }
            // A field that has just appeared is not yet in the window: focus set at once is lost.
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
            store.guidanceFocusServed = store.guidanceFocus
        }
    }
}
