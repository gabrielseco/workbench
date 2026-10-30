import SwiftUI

private struct GoalEditSerialKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    /// Counts the goal edits that have ended; a field shows what the file has again when it changes and the field is not being typed in.
    var goalEditSerial: Int {
        get { self[GoalEditSerialKey.self] }
        set { self[GoalEditSerialKey.self] = newValue }
    }
}

/// One line of the goal you can change in place. The change is made when you press Return or leave the field, never per
/// keystroke; Esc puts back what the file has. `commit` gets the trimmed text and only when it differs from `value`.
struct CommitField: View {
    var placeholder: String
    var value: String
    var font: Font = .body
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.goalEditSerial) private var serial

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(font)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onChange(of: serial) { _, _ in if !focused { text = value } }
            .onSubmit(push)
            .onChange(of: focused) { _, now in if !now { push() } }
            .onExitCommand { text = value }
    }

    private func push() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed != value { commit(trimmed) }
    }
}

/// The request: several lines in the serif face, changed on leaving the field.
struct CommitEditor: View {
    var value: String
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.goalEditSerial) private var serial

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 16, design: .serif)).lineSpacing(5)
            .scrollContentBackground(.hidden).scrollDisabled(true)
            .frame(minHeight: 30)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onChange(of: serial) { _, _ in if !focused { text = value } }
            .onChange(of: focused) { _, now in
                guard !now else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != value { commit(trimmed) }
            }
            .onExitCommand { text = value }
    }
}

/// A block of the goal: one rounded card around everything in it (not one card per child), the same whether it can be changed or not.
struct GoalCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// A new line to add (an out-of-scope item, a folder): nothing is written until it has text and you press Return or Add.
struct NewLine: View {
    var placeholder: String
    var add: (String) -> Void
    var cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(send).onExitCommand(perform: cancel)
            Button("Add", action: send).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", action: cancel)
        }
        .onAppear { focused = true }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { add(trimmed) }
    }
}

/// A new criterion to add: its text and how it will be shown, written together.
struct NewCriterionCard: View {
    var add: (String, String) -> Void
    var cancel: () -> Void
    @State private var text = ""
    @State private var proof = ""
    @FocusState private var focused: Bool

    private var ready: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && !proof.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        GoalCard {
            TextField("What must hold", text: $text).textFieldStyle(.roundedBorder).focused($focused)
            TextField("Proof: how it will be shown", text: $proof).textFieldStyle(.roundedBorder).onSubmit(send)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Add", action: send).disabled(!ready).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { focused = true }
    }

    private func send() {
        if ready { add(text.trimmingCharacters(in: .whitespaces), proof.trimmingCharacters(in: .whitespaces)) }
    }
}

/// A row whose buttons are quiet until the pointer is over it, so a column of them does not read as a column of icons.
struct HoverRow<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View { content(hovering).onHover { hovering = $0 } }
}

/// What kind of proof a criterion has, as a small label.
struct KindChip: View {
    var kind: String

    var body: some View {
        Text(kind).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.grey.opacity(0.14), in: Capsule())
    }
}
