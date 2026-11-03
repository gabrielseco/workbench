import SwiftUI
import WorkbenchCore

extension EnvironmentValues {
    /// Draws the feed's rows in a plain stack: `ImageRenderer` cannot draw a scroll view's content, so a test that renders the window
    /// sets this to see the rows. The app never does.
    @Entry var feedDrawsEagerly = false
}

/// The thread as one conversation (P22): what the title says, where the thread is, and everything that happened, newest at the foot.
/// It draws `snapshot.feed`, what the last action said and a decision card whose buttons run the actions the step screens run.
struct FeedScreen: View {
    var snapshot: ThreadSnapshot
    var store: ProjectStore
    @Environment(\.feedDrawsEagerly) private var drawsEagerly
    @State private var confirmingMerge = false
    @State private var reviewingDetails = false

    /// The feed's own rows, and the next-step card, which is drawn as the decision card instead.
    private var rows: [FeedItem] {
        if case .next? = snapshot.feed.last?.kind { return Array(snapshot.feed.dropLast()) }
        return snapshot.feed
    }

    /// The goal card is the editor while the goal may be changed: a draft, no turn run, nothing going on (the Run settings' rule).
    private var canEditGoal: Bool { store.feedEditsGoal(snapshot) }

    private func row(_ item: FeedItem) -> some View {
        FeedRow(item: item, goal: store.goal, store: store, editable: canEditGoal)
    }

    @ViewBuilder private var foot: some View {
        MessageRows(error: store.actionError, note: store.actionNote, notice: store.notice, handoff: store.herdrHandoffOutcome)
        if snapshot.watchesPullRequest, let ci = snapshot.ci { PullRequestCIView(ci: ci, store: store) }
        if case .next(let step, let why)? = snapshot.feed.last?.kind {
            DecisionCard(step: step, why: why, decision: store.feedDecision(for: snapshot), perform: perform)
        }
    }

    private func perform(_ action: FeedAction) {
        switch action.kind {
        case .merge: confirmingMerge = true
        case .reviewDetails: reviewingDetails = true
        default: Task { await store.perform(action.kind) }
        }
    }

    private var eagerRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row($0) }
            foot
        }
        .padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lazyRows: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row($0) }
            foot
        }
        .padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        GeometryReader { proxy in
            let beside = store.runSettingsOn && RunSettingsLayout.placement(centreWidth: proxy.size.width) == .beside
            HStack(spacing: 0) {
                column
                if beside {
                    Divider()
                    RunSettingsInspector(snapshot: snapshot, goal: store.goal, store: store).frame(width: RunSettingsLayout.width)
                }
            }
            // Too narrow for it beside the feed, it opens over it.
            .sheet(
                isPresented: Binding(
                    get: { store.runSettingsOn && !beside }, set: { if !$0 { store.setRunSettings(false) } })
            ) {
                RunSettingsSheet(snapshot: snapshot, store: store)
            }
        }
    }

    private var column: some View {
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
        // The review's own sheet asks for the discard when it is the one open, so two sheets never ask at once.
        .sheet(
            isPresented: Binding(
                get: { store.pendingDiscard != nil && !reviewingDetails }, set: { if !$0 { store.cancelDiscard() } })
        ) {
            DiscardSheet(store: store)
        }
        .sheet(isPresented: Binding(get: { store.prReviewShown != nil }, set: { if !$0 { store.closePRReview() } })) {
            PRReviewSheet(store: store)
        }
        .sheet(isPresented: $reviewingDetails) { ReviewDetailsSheet(snapshot: snapshot, store: store) }
        .confirmationDialog(mergeTitle, isPresented: $confirmingMerge) {
            Button("Merge") { Task { await store.mergePullRequest() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Squash-merges it on GitHub at the commit whose checks are green. This cannot be undone from Workbench.")
        }
    }

    private var mergeTitle: String { snapshot.state.pullRequest.map { "Merge PR #\($0.number)?" } ?? "Merge?" }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.title ?? snapshot.id).font(.title2.weight(.bold)).lineLimit(2)
                Spacer(minLength: 12)
                Button {
                    store.setRunSettings(!store.runSettingsOn)
                } label: {
                    Label("Run settings", systemImage: "sidebar.right")
                }
                .buttonStyle(.borderless).font(.callout)
                .help(store.runSettingsOn ? "Hides what this run is allowed to do" : "Shows what this run is allowed to do")
            }
            // A chat is on no step: it has no goal, no run and nothing to accept.
            if !(snapshot.state.isChat && snapshot.approval == nil) { PhaseRow(spine: snapshot.spine) }
        }
        .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 12)
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

/// The review of the latest turn over the feed: the Review screen as it is, with every criterion and where it stands, until the review
/// has a place of its own in the feed.
struct ReviewDetailsSheet: View {
    var snapshot: ThreadSnapshot
    var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if let review = store.review {
                ReviewView(review: review, finishedAt: snapshot.run?.endedAt, store: store)
            } else {
                Text("There is nothing to review now.").foregroundStyle(.secondary).padding(20)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}
