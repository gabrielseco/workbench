import SwiftUI

/// A single-line text field in the three looks the app has. A view never writes `TextField(` or `.textFieldStyle(.roundedBorder)`
/// (`scripts/check-banned-apis.sh` fails it): the look, the type style, the icon and the way the field is named and focused are props here.
/// What a field does (submit, escape) is the caller's, as modifiers; the key presses a field has to take before it does (the project picker's
/// arrows) are `keys`, since a handler on a container would come after the field's own.
struct TextInput: View {
    enum Look {
        /// No chrome: the text sits in what it is part of (an editable title in a card).
        case bare
        /// The system's bordered field, for a form.
        case bordered
        /// A grey well, with an optional symbol in front (a search, a model name).
        case filled
    }

    var placeholder: String
    @Binding var text: String
    var look: Look
    var style: TextStyle?
    var icon: String?
    /// A filled field in a row of controls (an agent's model) is a step shorter than one on its own (a search).
    var dense: Bool
    /// What assistive technology calls it, when the placeholder is not enough.
    var label: String?
    var focus: FocusState<Bool>.Binding?
    var keys: ((KeyPress) -> KeyPress.Result)?

    init(
        _ placeholder: String, text: Binding<String>, look: Look = .bordered, style: TextStyle? = nil, icon: String? = nil,
        dense: Bool = false, label: String? = nil, focus: FocusState<Bool>.Binding? = nil,
        keys: ((KeyPress) -> KeyPress.Result)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        (self.look, self.style, self.icon, self.dense) = (look, style, icon, dense)
        (self.label, self.focus, self.keys) = (label, focus, keys)
    }

    var body: some View {
        switch look {
        case .bare: field.textFieldStyle(.plain)
        case .bordered: field.textFieldStyle(.roundedBorder)
        case .filled:
            HStack(spacing: Space.s) {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                field.textFieldStyle(.plain)
            }
            .padding(.horizontal, Space.m).padding(.vertical, dense ? Space.xs : Space.s)
            .background(Theme.grey.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.box))
        }
    }

    @ViewBuilder private var field: some View {
        let base = TextField(placeholder, text: $text).textStyleIfSet(style).accessibilityLabelIfSet(label)
        if let focus {
            base.focused(focus).onKeyPress(phases: [.down, .repeat]) { keys?($0) ?? .ignored }
        } else {
            base.onKeyPress(phases: [.down, .repeat]) { keys?($0) ?? .ignored }
        }
    }
}

private extension View {
    @ViewBuilder func textStyleIfSet(_ style: TextStyle?) -> some View {
        if let style { textStyle(style) } else { self }
    }

    @ViewBuilder func accessibilityLabelIfSet(_ label: String?) -> some View {
        if let label { accessibilityLabel(label) } else { self }
    }
}

/// A switch with what it does beside it: the label, then the lines that say more. The switch is at the left, as the artboard has it, and
/// the neutral inverse instead of the system accent, which collides with the state colours.
struct SwitchRow: View {
    var title: String
    var details: [String]
    var isOn: Binding<Bool>
    var enabled: Bool

    init(_ title: String, details: [String] = [], isOn: Binding<Bool>, enabled: Bool = true) {
        (self.title, self.details, self.isOn, self.enabled) = (title, details, isOn, enabled)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch).labelsHidden().switchTint().controlSize(.small).disabled(!enabled)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).textStyle(.bodyMedium).fixedSize(horizontal: false, vertical: true)
                ForEach(details, id: \.self) {
                    Text($0).textStyle(.subheadline, .subtle).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
