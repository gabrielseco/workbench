import SwiftUI

/// How a result is told, once: its symbol, its colour and its word. The five state colours of docs/DESIGN.md each keep one meaning (green
/// done, red failed, amber needs you, blue working, grey quiet), and the symbol and the word mean colour is never the only signal. A view
/// never writes `"checkmark.circle.fill"` and `Theme.green` side by side: it names the outcome (`scripts/check-banned-apis.sh` fails the
/// literal outside this file). A result the cases lack is a new case, decided once.
enum Outcome: Equatable {
    case passed, failed, warning, pending, skipped, stopped, unknown
    /// Something that could not be read (the pull request's checks), which the person may want to look at.
    case unavailable

    var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .pending: "clock.fill"
        case .skipped: "minus.circle"
        case .stopped: "minus.circle.fill"
        case .unknown: "questionmark.circle"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .passed: Theme.green
        case .failed: Theme.red
        case .warning, .unavailable: Theme.amber
        case .pending: Theme.blue
        case .skipped, .stopped, .unknown: Theme.grey
        }
    }

    var word: String {
        switch self {
        case .passed: "passed"
        case .failed: "failed"
        case .warning: "needs you"
        case .pending: "running"
        case .skipped: "skipped"
        case .stopped: "stopped"
        case .unknown: "unknown"
        case .unavailable: "unavailable"
        }
    }
}

extension TaskTone {
    /// The outcome a task's tone is shown as; a task that is working has a mark of its own, not one of these.
    var outcome: Outcome? {
        switch self {
        case .done: .passed
        case .idle: .skipped
        case .needsYou: .warning
        case .broken: .failed
        case .working: nil
        }
    }
}

/// The symbol of an outcome in its colour.
struct StatusMark: View {
    var outcome: Outcome

    init(_ outcome: Outcome) { self.outcome = outcome }

    var body: some View {
        Image(systemName: outcome.symbol).foregroundStyle(outcome.tint)
    }
}

extension FeedLine {
    /// A line told by an outcome: its symbol and colour.
    init(_ outcome: Outcome, title: String, detail: String? = nil, mono: Bool = false, inline: Bool = false, link: Bool = false) {
        self.init(
            symbol: outcome.symbol, tint: outcome.tint, title: title, detail: detail, mono: mono, inline: inline, link: link)
    }
}

/// What kind of thing a notice says, which fixes its symbol and its colour.
enum MessageKind {
    /// Something failed: red, and its words in red.
    case error
    /// A refusal that asks the person to change something: amber.
    case warning
    /// A fact: grey.
    case info
    /// A thing that was done: green.
    case success

    var symbol: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .error: Theme.red
        case .warning: Theme.amber
        case .info: Theme.grey
        case .success: Theme.green
        }
    }
}

/// A sentence the app says about what just happened (a `Message`): a symbol in the kind's colour, then the words (red for an error, the text
/// colour for the rest). It is selectable, since it is often a path or a command to copy. `.caption` is the small form for a line inside a card.
struct Message: View {
    enum Size { case callout, caption }

    var kind: MessageKind
    var text: String
    var size: Size

    init(_ kind: MessageKind, _ text: String, size: Size = .callout) {
        (self.kind, self.text, self.size) = (kind, text, size)
    }

    var body: some View {
        IconRow(symbol: kind.symbol, tint: kind.tint) {
            Group {
                if kind == .error {
                    Text(text).textStyle(size == .callout ? .callout : .caption, .red)
                } else {
                    Text(text).textStyle(size == .callout ? .callout : .caption)
                }
            }
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}
