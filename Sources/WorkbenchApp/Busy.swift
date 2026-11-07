import SwiftUI

/// The indeterminate spinner, in the sizes the app uses. A view never writes `ProgressView()` (`scripts/check-banned-apis.sh` fails it).
struct Spinner: View {
    enum Size {
        case small
        case mini
        /// The thread list's mark: a small spinner shrunk to sit in a rail column, in the working blue.
        case rail
    }

    var size: Size
    /// In a row's symbol column, so what follows lines up with the symbols of the rows around it.
    var inColumn: Bool

    init(_ size: Size = .small, inColumn: Bool = false) { (self.size, self.inColumn) = (size, inColumn) }

    var body: some View {
        switch size {
        case .small: ProgressView().controlSize(.small).frame(width: inColumn ? SymbolColumn.regular.width : nil)
        case .mini: ProgressView().controlSize(.mini).frame(width: inColumn ? SymbolColumn.narrow.width : nil)
        case .rail: ProgressView().controlSize(.small).scaleEffect(0.7).tint(Theme.blue)
        }
    }
}

/// What the app is doing while it works: a spinner and the words, and the way to stop it when it can be stopped.
struct BusyLine: View {
    /// How it is told: quiet for the window's own busy line, working (blue, the meaning of work going on) for what a person started.
    enum Tone { case quiet, working }

    struct Stop {
        var title: String
        var label: String?
        var disabled = false
        var perform: () -> Void
    }

    var text: String
    var tone: Tone
    var stop: Stop?
    /// The stop button at the far edge of the row, not beside the words.
    var spread: Bool
    /// The spinner over the words, for a screen that is only waiting.
    var stacked: Bool

    init(_ text: String, tone: Tone = .quiet, stop: Stop? = nil, spread: Bool = false, stacked: Bool = false) {
        (self.text, self.tone, self.stop, self.spread, self.stacked) = (text, tone, stop, spread, stacked)
    }

    var body: some View {
        if stacked {
            VStack(spacing: Space.s) {
                Spinner()
                words
            }
        } else {
            HStack(spacing: Space.s) {
                Spinner()
                words
                if spread { Spacer() }
                if let stop {
                    Button(stop.title, action: stop.perform).buttonStyle(.borderless).disabled(stop.disabled)
                        .accessibilityLabel(stop.label ?? stop.title)
                }
            }
        }
    }

    @ViewBuilder private var words: some View {
        switch tone {
        case .quiet: Text(text).role(.detail)
        case .working: Text(text).textStyle(.callout, .blue)
        }
    }
}
