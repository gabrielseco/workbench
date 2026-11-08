import AppKit
import SwiftUI
import WorkbenchCore

struct RootView: View {
    var store: ProjectStore

    var body: some View {
        VStack(spacing: 0) {
            ToolbarBar(store: store)
            Divider()
            HStack(spacing: 0) {
                ProjectRail(store: store).background(Theme.rail)
                Divider()
                if !store.automationsListShown {
                    PreviewRail(store: store).frame(width: PreviewRail.width).background(Theme.rail)
                    Divider()
                }
                Centre(store: store).frame(maxWidth: .infinity, maxHeight: .infinity).background { Theme.canvas }
            }
            Divider()
            FooterBar(store: store)
        }
        .frame(minWidth: 900, minHeight: 600)
        .appModals(store)
        .environment(\.openScreenshotPreview) { store.modals.preview = $0 }
    }
}

/// The project's name, the Inbox / Automations switch, the base, the state pill and the spend meter. Projects are the rail's, and so are their agents (its tile menu, ⌘,).
struct ToolbarBar: View {
    var store: ProjectStore

    var body: some View {
        HStack(spacing: Space.m) {
            // The project is named here, as the design has it; switching and adding are the rail's.
            Text(store.project?.root.lastPathComponent ?? "No project").textStyle(.bodyStrong)
            // The base follows the name on every screen, as the design has it; the spend and the state are the thread's, not shown
            // over the Automations screen, where amber means something else.
            if !store.newThread, case .thread(let snapshot) = store.screen, let base = snapshot.base {
                Text("base: \(base)").textStyle(.monoCallout)
            }
            SegmentedSwitch(
                segments: store.switchSegments(), selection: store.switchSelection, enabled: store.project != nil,
                onFocus: { store.switchFocused = $0 }, action: { store.chooseSwitch($0) }
            )
            Spacer()
            if store.newThread {
                // Nothing is running and no thread is on screen: the design's `$0.00` and `No run`.
                Text("$0.00").role(.monoDetail)
                Text("No run").pill(Theme.grey, size: .regular)
            } else if store.mode == .thread, case .thread(let snapshot) = store.screen {
                Text(snapshot.spendText).role(.monoDetail)
                StatePill(snapshot: snapshot)
            } else if store.mode == .tasks, store.project != nil {
                Button("New task…") { store.beginNewTask() }.plainButton(size: .regular).help("Make a scheduled task (⇧⌘N)")
            }
        }
        .padding(.horizontal, Spacing.inset).padding(.vertical, Space.m)
    }
}

struct StatePill: View {
    var snapshot: ThreadSnapshot

    /// What the pill says: only the head of the state (`Needs you`); the reason is in the thread's row and the decision card.
    static func text(_ snapshot: ThreadSnapshot) -> String { snapshot.stateHead }

    var body: some View {
        let tint: Color = {
            if case .needsYou = snapshot.attention { return Theme.amber }
            if snapshot.attention == .working { return Theme.blue }
            return Theme.grey
        }()
        Text(Self.text(snapshot)).pill(tint, size: .regular)
    }
}

struct DoctorButton: View {
    var store: ProjectStore
    /// The footer's form: a word and its result, no frame.
    var compact = false

    var body: some View {
        Button {
            Task { await store.runDoctor() }
        } label: {
            HStack(spacing: compact ? Space.s : nil) {
                Text("Doctor")
                if !compact { Spacer() }
                switch store.doctor {
                case .notRun: Text("Not run").foregroundStyle(.secondary)
                case .running: Spinner()
                case .healthy(let seconds):
                    Text(String(format: "Healthy · %.1fs", seconds)).foregroundStyle(Theme.green)
                case .problem: Text("Problem").foregroundStyle(Theme.red)
                }
            }
            .padding(compact ? Space.none : Space.s)
            .callout(.outlined, enabled: !compact)
        }
        .buttonStyle(.plain)
        .disabled(store.project == nil)
        .help(doctorHelp)
    }

    private var doctorHelp: String {
        if case .problem(let text) = store.doctor { return text }
        return "Runs the project's setup and check in a throwaway worktree"
    }
}

struct Centre: View {
    var store: ProjectStore

    var body: some View {
        if store.newThread, store.project != nil {
            NewThreadScreen(store: store)
        } else if store.mode == .tasks, store.project != nil {
            TasksView(store: store)
        } else if case .thread(let snapshot) = store.screen {
            FeedScreen(snapshot: snapshot, store: store)
        } else if let message = store.screen.message {
            EmptyState(title: message.title, next: message.next, store: store)
        }
    }
}

/// What the app is doing for the person right now: a click is answered at once, even when the work behind it takes a while.
struct BusyBar: View {
    var text: String

    var body: some View {
        BusyLine(text)
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .callout()
            .accessibilityElement(children: .combine)
    }
}

/// Where "Fix failed checks" is, on the thread it was pressed on and on the follow-up that fixes it: the follow-up is not shipped, so it
/// has no CI banner to carry the line.
struct CIFixLine: View {
    var store: ProjectStore

    var body: some View {
        if let fix = store.ciFixShown(on: store.currentThread) {
            if fix.active {
                BusyLine(fix.line, tone: .working)
            } else {
                Text(fix.line).role(fix.failed ? .error : .detail)
            }
        }
    }
}

/// The shipped pull request's CI as GitHub said it last: one line, then one row per check, and why Merge waits when it does.
struct PullRequestCIView: View {
    var ci: PullRequestCI
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Label(ci.summary, systemImage: outcome.symbol).foregroundStyle(outcome.tint).textStyle(.callout)
                Button("Refresh") { Task { await store.refreshPullRequestCI() } }.buttonStyle(.link).textStyle(.callout)
            }
            // The banner sits outside the scrolling content, so a long list scrolls in its own box instead of pushing the window.
            if ci.rows.count > Self.unscrolledRows {
                ScrollView { rows }.frame(maxHeight: 130)
            } else {
                rows
            }
            if !ci.canMerge, let blocker = ci.mergeBlocker, ci.unavailableReason == nil {
                Text("Merge waits: \(blocker)").role(.detail)
            }
        }
    }

    static let unscrolledRows = 6

    private var rows: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(ci.rows, id: \.self) { row in
                HStack(spacing: Space.s) {
                    StatusMark(rowOutcome(row.kind))
                    Text(row.name).textStyle(.monoCallout)
                    Text(row.word).role(.detail)
                }
                .padding(.leading, Space.xl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outcome: Outcome {
        if ci.unavailableReason != nil { return .unavailable }
        if ci.isPending { return .pending }
        switch ci.status?.checks?.state {
        case .passed?: return .passed
        case .failed?: return .failed
        default: return .skipped
        }
    }

    private func rowOutcome(_ kind: PullRequestCI.Row.Kind) -> Outcome {
        switch kind {
        case .passed: .passed
        case .skipped: .skipped
        case .running: .pending
        case .failed: .failed
        }
    }
}

struct EmptyState: View {
    var title: String
    var next: String
    var store: ProjectStore

    var body: some View {
        VStack(spacing: Space.m) {
            Text(title).textStyle(.title)
            Text(next).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Choose project…") { Task { await store.chooseFolder() } }
                if store.screen == .noThread { Button("New goal…") { store.beginNewGoal() } }
            }
            .padding(.top, Space.s)
            if let error = store.actionError { Text(error).role(.error) }
        }
        .padding(Space.huge)
    }
}

struct FooterBar: View {
    var store: ProjectStore

    var body: some View {
        HStack {
            if let url = store.logURL, !store.newThread {
                Button {
                    // A .jsonl may have no app to open it: show it in Finder rather than do nothing.
                    if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: {
                    Label(label, systemImage: "doc.text").foregroundStyle(Theme.blue)
                }
                .plainButton(size: .small)
                .help("Opens the raw log file")
            } else {
                Text("Nothing is running.").foregroundStyle(.secondary)
            }
            DoctorButton(store: store, compact: true).textStyle(.callout)
            Spacer()
            if let limit = FooterBar.limitText(store.screen, mode: store.mode, composing: store.newThread) {
                Text(limit).role(.mono)
            }
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
    }

    /// The thread's per-turn limit, as the design's footer says it; nil when the thread has none or is not on screen.
    static func limitText(_ screen: ProjectScreen, mode: WindowMode, composing: Bool = false) -> String? {
        // The thread stays loaded behind the Tasks screen, which has limits of its own: it says nothing there.
        guard mode == .thread, !composing, case .thread(let snapshot) = screen, let minutes = snapshot.turnTimeoutMin else {
            return nil
        }
        return "\(minutes) min per turn"
    }

    private var label: String {
        if case .thread(let snapshot) = store.screen { return "Event log \(snapshot.lastSeq)" }
        return "Open the event log"
    }
}
