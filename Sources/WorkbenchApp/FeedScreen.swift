import SwiftUI
import WorkbenchCore

extension EnvironmentValues {
    /// Draws the feed's rows in a plain stack: `ImageRenderer` cannot draw a scroll view's content, so a test that renders the window
    /// sets this to see the rows. The app never does.
    @Entry var feedDrawsEagerly = false
}

/// The thread as one conversation (P22): what the title says, where the thread is, and everything that happened, newest at the foot.
/// It draws `snapshot.feed` and nothing else, and it acts on nothing yet: the step screens still hold every button.
struct FeedScreen: View {
    var snapshot: ThreadSnapshot
    var store: ProjectStore
    @Environment(\.feedDrawsEagerly) private var drawsEagerly

    private var eagerRows: some View {
        VStack(alignment: .leading, spacing: 10) { ForEach(snapshot.feed) { FeedRow(item: $0) } }
            .padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lazyRows: some View {
        LazyVStack(alignment: .leading, spacing: 10) { ForEach(snapshot.feed) { FeedRow(item: $0) } }
            .padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let busy = store.busy { BusyBar(text: busy).padding(.horizontal, 28).padding(.top, 12) }
            header
            Divider()
            if drawsEagerly {
                eagerRows.frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                ScrollView { lazyRows }
                    // The feed opens at its newest row and stays there while it grows; a person who scrolled up is left where they are.
                    .defaultScrollAnchor(.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.title ?? snapshot.id).font(.title2.weight(.bold)).lineLimit(2)
            PhaseRow(spine: snapshot.spine)
        }
        .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 12)
    }
}

/// The spine as a row under the title: the same seven steps, marks and colours as the rail drew them.
struct PhaseRow: View {
    var spine: ThreadSpine

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(spine.entries.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 4) {
                    Image(systemName: entry.mark.symbol).foregroundStyle(Theme.color(for: entry.mark))
                    Text(entry.step.title)
                        .font(.callout.weight(entry.mark == .pending ? .regular : .semibold))
                        .foregroundStyle(entry.mark == .pending ? Color.secondary : Color.primary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.step.title), \(entry.mark.rawValue), \(entry.sublabel)")
                if index < spine.entries.count - 1 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
