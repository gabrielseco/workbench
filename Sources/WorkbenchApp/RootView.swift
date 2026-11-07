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
                PreviewRail(store: store).frame(width: PreviewRail.width).background(Theme.rail)
                Divider()
                Centre(store: store).frame(maxWidth: .infinity, maxHeight: .infinity).background { Theme.canvas }
            }
            Divider()
            FooterBar(store: store)
        }
        .frame(minWidth: 900, minHeight: 600)
        .appModals(store)
    }
}

/// The project pill, the base, the state pill and the spend meter.
struct ToolbarBar: View {
    var store: ProjectStore

    /// What the project pill is called to assistive technology, and so to scripts/verify-app.sh: it opens the project card, not a
    /// panel, so the script may press it; the card's "Choose folder…" is the one it refuses.
    static func projectButtonLabel(_ project: Project?) -> String {
        "Projects" + (project.map { ", now \($0.root.lastPathComponent)" } ?? "")
    }

    var body: some View {
        HStack(spacing: Space.m) {
            ProjectPill(store: store)
            AgentsPill(store: store)
            // The base, the spend and the state are the thread's: not shown over the Tasks screen, where amber means something else.
            if store.newThread {
                // Nothing is running and no thread is on screen: the design's `$0.00` and `No run`.
                Spacer()
                Text("$0.00").role(.monoDetail)
                Text("No run").pill(Theme.grey, size: .regular)
            } else if store.mode == .thread, case .thread(let snapshot) = store.screen {
                if let base = snapshot.base { Text("base: \(base)").textStyle(.monoCallout) }
                Spacer()
                Text(snapshot.spendText).role(.monoDetail)
                StatePill(snapshot: snapshot)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, Spacing.inset).padding(.vertical, Space.m)
    }
}

/// The open project's name with a folder and a chevron; it opens the project card.
struct ProjectPill: View {
    var store: ProjectStore
    @State private var hovered = false

    var body: some View {
        Button {
            store.pickingProject.toggle()
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.blue)
                Text(store.project?.root.lastPathComponent ?? "Choose project").textStyle(.bodyStrong)
                Image(systemName: "chevron.down").textStyle(.captionStrong, .secondary)
            }
            .pill(style: .control(hovered: hovered, selected: store.pickingProject), size: .large)
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovered = $0 }
        .accessibilityLabel(ToolbarBar.projectButtonLabel(store.project))
        .help(store.project?.root.path ?? "Choose a project")
    }
}

/// What the project's coding agent is, and the way to the Agents card (also ⌘,): the card was a link at the foot of the rail.
struct AgentsPill: View {
    var store: ProjectStore
    @State private var hovered = false

    /// "Codex · gpt-6.1-terra" for the run role; "Agents" when the config is unread, missing or has no such row.
    static func text(_ setup: AgentSetup?) -> String { setup?.row(.run)?.label ?? "Agents" }

    var body: some View {
        Button {
            store.showingAgents.toggle()
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "cpu").textStyle(.captionStrong, .secondary)
                // A model named by hand can be long: truncate so the base, spend and state keep their room.
                Text(Self.text(store.agentSetup)).textStyle(.body).lineLimit(1).truncationMode(.tail).frame(maxWidth: 220)
            }
            .pill(style: .control(hovered: hovered, selected: store.showingAgents), size: .large)
        }
        .buttonStyle(.plain).fixedSize()
        .disabled(store.project == nil)
        .onHover { hovered = $0 }
        .accessibilityLabel("Agents")
        .help("\(Self.text(store.agentSetup)): which provider and model each agent role of this project uses (⌘,)")
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
                case .running: ProgressView().controlSize(.small)
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
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text(text).role(.detail)
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .callout()
        .accessibilityElement(children: .combine)
    }
}

/// The shipped pull request's CI as GitHub said it last: one line, then one row per check, and why Merge waits when it does.
struct PullRequestCIView: View {
    var ci: PullRequestCI
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Label(ci.summary, systemImage: icon).foregroundStyle(color).textStyle(.callout)
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
                    Image(systemName: rowIcon(row.kind)).foregroundStyle(rowColor(row.kind))
                    Text(row.name).textStyle(.monoCallout)
                    Text(row.word).role(.detail)
                }
                .padding(.leading, Space.xl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var icon: String {
        if ci.unavailableReason != nil { return "questionmark.circle.fill" }
        if ci.isPending { return "clock.fill" }
        switch ci.status?.checks?.state {
        case .passed?: return "checkmark.circle.fill"
        case .failed?: return "xmark.circle.fill"
        default: return "minus.circle"
        }
    }

    private var color: Color {
        if ci.unavailableReason != nil { return Theme.amber }
        if ci.isPending { return Theme.blue }
        switch ci.status?.checks?.state {
        case .passed?: return Theme.green
        case .failed?: return Theme.red
        default: return .secondary
        }
    }

    private func rowIcon(_ kind: PullRequestCI.Row.Kind) -> String {
        switch kind {
        case .passed: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .running: "clock"
        case .failed: "xmark.circle.fill"
        }
    }

    private func rowColor(_ kind: PullRequestCI.Row.Kind) -> Color {
        switch kind {
        case .passed: Theme.green
        case .skipped: Theme.grey
        case .running: Theme.blue
        case .failed: Theme.red
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
