import SwiftUI

/// The artboards' buttons (design parity 9): the primary one is the inverse pill, the plain one a raised bordered button. With the chat
/// feed preview off both are the system's, so the old window does not change; P22 slice 7 deletes the fallback.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.invfg)
            .padding(.horizontal, 16).frame(minHeight: 34)
            // Pressed is darker in both appearances (a lower opacity would fade toward the canvas, lighter on the light one).
            .background {
                RoundedRectangle(cornerRadius: 7).fill(Theme.inv).brightness(configuration.isPressed ? -0.2 : 0)
            }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct PlainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    /// Fills the width and puts the label at the left, as the panel's Open buttons do.
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).frame(maxWidth: fill ? .infinity : nil, minHeight: 30, alignment: fill ? .leading : .center)
            .background(Theme.raised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Which style a modifier hands out: ours with the preview on, the system's without. Pure, so a test can read both.
enum ButtonChoice: Equatable {
    case ours, system

    static func pick(preview: Bool) -> ButtonChoice { preview ? .ours : .system }
}

extension View {
    /// The button the screen's one main action uses.
    @ViewBuilder func primaryButton() -> some View {
        if ButtonChoice.pick(preview: Theme.preview) == .ours {
            buttonStyle(PrimaryButtonStyle())
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Any other button that is a button (not an icon or a link).
    @ViewBuilder func plainButton(fill: Bool = false) -> some View {
        if ButtonChoice.pick(preview: Theme.preview) == .ours {
            buttonStyle(PlainButtonStyle(fill: fill))
        } else {
            buttonStyle(.bordered)
        }
    }

    /// A native switch in the artboards' neutral inverse instead of the person's system accent, which collides with the state colours.
    @ViewBuilder func switchTint() -> some View {
        if ButtonChoice.pick(preview: Theme.preview) == .ours { tint(Theme.inv) } else { self }
    }
}
