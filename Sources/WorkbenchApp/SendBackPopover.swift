import SwiftUI
import WorkbenchCore

/// Asks what should change and starts the next turn with it, in the same card New goal is. The card stays up, with the text,
/// when the send is refused (a bad budget): it closes only when a turn has started.
struct SendBackPopover: View {
    var store: ProjectStore
    @State private var note = ""
    @State private var budget = ""
    @FocusState private var focused: Bool

    private var empty: Bool { note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            writing.padding(.top, 16)
            TextField("Budget for this turn, in dollars (optional)", text: $budget)
                .textFieldStyle(.roundedBorder).padding(.top, 14)
            if let error = store.actionError {
                Text(error).font(.callout).foregroundStyle(Theme.red).padding(.top, 14)
            }
            footer.padding(.top, 26)
        }
        .overlayCard()
        .onExitCommand(perform: close)
        .onAppear { store.actionError = nil }
        // An overlay is not yet in the window when `onAppear` runs, and focus set then is lost: one tick later it takes.
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
        }
    }

    private func close() { store.sendingBack = false }

    private var header: some View {
        HStack {
            Text("Send back".uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.9).foregroundStyle(.secondary)
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Close the send back panel")
        }
    }

    private var writing: some View {
        TextEditor(text: $note)
            .font(.system(size: 17, design: .serif)).lineSpacing(6)
            .focused($focused).scrollContentBackground(.hidden)
            .frame(height: 170)
            .overlay(alignment: .topLeading) {
                if note.isEmpty {
                    Text("What should change? Say what is wrong and what you expect instead.")
                        .font(.system(size: 17, design: .serif)).lineSpacing(6)
                        .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("The next turn also gets the failed check's output.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button("Send back") { store.sendBack(note: note, budget: budget) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command).disabled(empty)
        }
    }
}
