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

    /// The live card for a turn that is working, with the rows it stands for taken out of the list.
    private var runCard: RunCardModel? { RunCardModel.make(snapshot: snapshot, decision: store.feedDecision(for: snapshot)) }

    /// The latest finished turn, where "Run finished" can say how many files changed and open the diff.
    private var finishedTurnID: String? {
        guard let last = snapshot.feed.last(where: { if case .turn = $0.kind { true } else { false } }),
            case .turn(_, .ended(let result), _, _) = last.kind, result == "succeeded"
        else { return nil }
        return last.id
    }

    private var latestVerifyID: String? { snapshot.feed.last(where: { if case .verify = $0.kind { true } else { false } })?.id }

    private func finish(for item: FeedItem) -> FinishContext? {
        guard item.id == finishedTurnID else { return nil }
        let tasks = snapshot.feed.compactMap { entry -> Int? in
            if case .plan(let list) = entry.kind, entry.turn == item.turn { list.count } else { nil }
        }.first
        let totals = store.review.map(\.totals).flatMap { $0.isEmpty ? nil : $0 }
        return FinishContext(tasks: tasks, totals: totals)
    }

    private func shots(for item: FeedItem) -> [ProofShot] {
        let proof = snapshot.state.review.verifier?.proof
        guard item.id == latestVerifyID, let project = store.project, let proof else { return [] }
        return ProofShot.shots(from: proof, threadDirectory: project.threadDirectory(snapshot.id))
    }

    private func row(_ item: FeedItem) -> some View {
        FeedRow(
            item: item, goal: store.goal, store: store, editable: canEditGoal,
            draft: canEditGoal
                ? DraftGoalContext(snapshot: snapshot, decision: store.feedDecision(for: snapshot), perform: perform) : nil,
            brainstorm: BrainstormFold.shown(state: snapshot.state) ? snapshot.state.chat?.messages ?? [] : [],
            finish: finish(for: item), shots: shots(for: item))
    }

    @ViewBuilder private var foot: some View {
        MessageRows(error: store.actionError, note: store.actionNote, notice: store.notice, handoff: store.herdrHandoffOutcome)
        if snapshot.watchesPullRequest, let ci = snapshot.ci { PullRequestCIView(ci: ci, store: store) }
        let draftCard = DraftGoalCard.hidesDecisionCard(editable: canEditGoal)
        if case .next(let step, let why)? = snapshot.feed.last?.kind, !draftCard, runCard?.stop == nil {
            let decision = store.feedDecision(for: snapshot)
            DecisionCard(
                step: step, why: why, decision: decision, perform: perform,
                route: snapshot.base.map { "\(WorktreeManager.branch(for: snapshot.id)) → \($0)" })
            if decision.takesGuidance { GuidanceField(store: store) }
        }
    }

    private func perform(_ action: FeedAction) {
        switch action.kind {
        case .merge: confirmingMerge = true
        case .reviewDetails: reviewingDetails = true
        default: Task { await store.perform(action.kind) }
        }
    }

    /// What the scroll shows: a chat's conversation, or the thread's feed with its foot.
    @ViewBuilder private var content: some View {
        if snapshot.showsChat {
            ChatRows(snapshot: snapshot, store: store)
        } else {
            let card = runCard
            ForEach(rows.filter { !(card?.consumed.contains($0.id) ?? false) }) { row($0) }
            if let card { RunCardView(model: card, perform: perform) }
            let pending = PendingStep.shown(
                goal: store.goal, criteria: store.goal?.rows.count ?? 0, working: card != nil,
                judgeRunning: snapshot.state.review.judge?.isOpen == true,
                verifyRunning: snapshot.state.review.verifier?.open == true)
            ForEach(pending) { PendingStepRow(step: $0) }
            foot
        }
    }

    private var eagerRows: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            content
        }
        .frame(maxWidth: FeedLayout.maxColumn, alignment: .leading)
        .padding(.horizontal, Spacing.gutter).padding(.vertical, Space.xl).frame(maxWidth: .infinity, alignment: .center)
    }

    private var lazyRows: some View {
        LazyVStack(alignment: .leading, spacing: Space.m) {
            content
        }
        .frame(maxWidth: FeedLayout.maxColumn, alignment: .leading)
        .padding(.horizontal, Spacing.gutter).padding(.vertical, Space.xl).frame(maxWidth: .infinity, alignment: .center)
    }

    var body: some View {
        GeometryReader { proxy in
            let beside = store.runSettingsOn && RunSettingsLayout.placement(centreWidth: proxy.size.width) == .beside
            HStack(spacing: 0) {
                column
                if beside {
                    Divider()
                    RunSettingsInspector(snapshot: snapshot, goal: store.goal, store: store).frame(width: RunSettingsLayout.width)
                        .background(Theme.rail)
                }
            }
            .onChange(of: proxy.size.width, initial: true) { _, width in
                store.runSettingsFits = RunSettingsLayout.placement(centreWidth: width) == .beside
            }
            // Too narrow for it beside the feed, it opens over it.
            .sheet(
                isPresented: Binding(
                    get: { store.runSettingsOn && store.runSettingsChosen && !beside },
                    set: { if !$0 { store.setRunSettings(false) } })
            ) {
                RunSettingsSheet(snapshot: snapshot, store: store)
            }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let busy = store.busy { BusyBar(text: busy).padding(.horizontal, Spacing.gutter).padding(.top, Space.m) }
            header
            Divider()
            if drawsEagerly {
                eagerRows.frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                ScrollView { lazyRows }
                    // The feed opens at its newest row and stays there while it grows; a person who scrolled up is left where they are.
                    .defaultScrollAnchor(.bottom)
            }
            if snapshot.showsChat {
                Divider()
                ChatComposer(snapshot: snapshot, store: store)
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

    /// The row is under every thread's title, a chat's too: a chat is the first step of the thread, not outside it.
    static func showsPhaseRow(_ snapshot: ThreadSnapshot) -> Bool { true }

    private var mergeTitle: String { snapshot.state.pullRequest.map { "Merge PR #\($0.number)?" } ?? "Merge?" }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.title ?? snapshot.id).textStyle(.section).lineLimit(2)
                Spacer(minLength: 12)
                let showing = store.runSettingsShowing
                Button {
                    store.toggleRunSettings()
                } label: {
                    Label("Run settings", systemImage: "sidebar.right")
                }
                .buttonStyle(.borderless).textStyle(.callout)
                .help(showing ? "Hides what this run is allowed to do" : "Shows what this run is allowed to do")
            }
            if Self.showsPhaseRow(snapshot) { PhaseRow(snapshot: snapshot) }
        }
        .padding(.horizontal, Spacing.gutter).padding(.top, Space.l).padding(.bottom, Space.m)
    }
}

/// How wide the feed's column is (the artboards': a centred column, not the window): rows, the foot and a chat's composer share it.
enum FeedLayout {
    static let maxColumn: CGFloat = 680
    /// What a chat's message bubbles and agent text are kept to inside it.
    static let userBubble: CGFloat = 540
    static let agentText: CGFloat = 620
}

/// One step of the phase row, as it is drawn and as VoiceOver says it.
struct PhaseStep: Equatable {
    var title: String
    var mark: SpineMark
    var sublabel: String

    var spoken: String { "\(title), \(mark.rawValue), \(sublabel)" }
}

/// How a step's dot and label look: the artboards' small dot with a ring, filled when the step is done or current and hollow when it is
/// still to come, with the label going from quiet to plain as the step is reached.
struct PhaseDot: Equatable {
    enum Label: Equatable { case secondary, primary, tertiary }
    var filled: Bool
    var label: Label

    static func of(_ mark: SpineMark) -> PhaseDot {
        switch mark {
        case .done: PhaseDot(filled: true, label: .secondary)
        case .current, .needsYou, .failed: PhaseDot(filled: true, label: .primary)
        case .pending: PhaseDot(filled: false, label: .tertiary)
        }
    }
}

/// The spine as a row under the title: the same steps, marks and colours as the rail drew them, in the artboards' form. A thread that began
/// as a chat has a Chat step first; a thread that began as a goal never had one.
struct PhaseRow: View {
    var steps: [PhaseStep]

    init(snapshot: ThreadSnapshot) { steps = Self.steps(for: snapshot) }
    init(steps: [PhaseStep]) { self.steps = steps }

    /// The row of a thread that does not exist yet (the new-thread screen): Chat is where it starts, and nothing else is reached.
    static var newThreadSteps: [PhaseStep] {
        [PhaseStep(title: "Chat", mark: .current, sublabel: "talking it through")]
            + SpineStep.allCases.map { PhaseStep(title: $0.title, mark: .pending, sublabel: "") }
    }

    /// The steps for a thread: the spine's seven (a chat that has no goal is on none of them), with Chat first when the thread began as a chat.
    static func steps(for snapshot: ThreadSnapshot) -> [PhaseStep] {
        let noGoal = snapshot.showsChat
        var steps = snapshot.spine.entries.map {
            PhaseStep(title: $0.step.title, mark: noGoal ? .pending : $0.mark, sublabel: noGoal ? "" : $0.sublabel)
        }
        if snapshot.state.isChat {
            let chat = noGoal
                ? PhaseStep(title: "Chat", mark: .current, sublabel: "talking it through")
                : PhaseStep(title: "Chat", mark: .done, sublabel: "became the goal")
            steps.insert(chat, at: 0)
        }
        return steps
    }

    var body: some View {
        HStack(spacing: Space.l) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                let dot = PhaseDot.of(step.mark)
                let tint = Theme.color(for: step.mark)
                HStack(spacing: Space.s) {
                    Circle().fill(dot.filled ? tint : Color.clear)
                        .overlay(Circle().strokeBorder(tint, lineWidth: 1.5)).frame(width: 8, height: 8)
                    Text(step.title).textStyle(.callout).lineLimit(1)
                        .foregroundStyle(
                            dot.label == .primary ? Color.primary : dot.label == .secondary ? Theme.fg2 : Theme.fg3)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(step.spoken)
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
                Text("Review").textStyle(.heading)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Space.xl).padding(.vertical, Space.m)
            Divider()
            if let review = store.review {
                ReviewView(review: review, finishedAt: snapshot.run?.endedAt, store: store)
            } else {
                Text("There is nothing to review now.").foregroundStyle(.secondary).padding(Space.xl)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}
