import SwiftUI
import WorkbenchCore

/// The rail (design parity 4): one list, *Threads* with a `+`, then *Scheduled* with the project's tasks.
/// There is no Thread/Tasks switch: choosing a row shows that thread or that task.
struct PreviewRail: View {
    var store: ProjectStore
    static let width: CGFloat = 288

    var body: some View {
        let snapshot = store.tasks.snapshot(for: store.project)
        let inbox = InboxModel.derive(
            listing: store.threads.listing, tasks: snapshot, composing: store.newThread, shown: store.railShown,
            doneOpen: store.doneOpen)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxs) {
                if store.allProjects {
                    allProjectsContent
                } else {
                    projectContent(inbox: inbox)
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.m)
            // One focus stop for the whole rail, so the arrows walk the threads and on into the tasks instead of stopping at the section edge.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard direction == .up || direction == .down else { return }
                if store.allProjects {
                    Task { await store.stepAllInbox(up: direction == .up) }
                } else {
                    move(up: direction == .up, inbox: inbox)
                }
            }
        }
        // The tasks are read while the rail is on screen, as the Tasks screen did while it was: the section is never stale for long.
        .task(id: store.project?.root.path) {
            var first = true
            while !Task.isCancelled {
                if first { await store.refreshAgentSetup() }
                await store.tasks.refreshIfDue(store.project, visible: true, force: first)
                first = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The row above or below the one shown, in the order the rail draws them; nil at either end or when none is shown.
    private func move(up: Bool, inbox: InboxModel) {
        let ids = inbox.navigation(scheduled: [])
        let thread = store.mode == .thread && !store.newThread ? shownThreadID : nil
        guard let shown = inbox.navigationID(thread: thread, task: shownTaskName),
            let next = InboxModel.neighbour(of: shown, in: ids, up: up)
        else { return }
        let key = String(next.dropFirst(2))
        if next.hasPrefix("t:") {
            Task { await store.select(thread: key) }
        } else {
            store.selectTask(key)
        }
    }

    private var shownThreadID: String? {
        if case .thread(let snapshot) = store.screen { return snapshot.id }
        return nil
    }

    /// The task on screen, when a task is: the highlighted row. The first one the Tasks screen would pick when none was chosen.
    private var shownTaskName: String? {
        guard store.mode == .tasks, !store.newThread, let snapshot = store.tasks.snapshot(for: store.project) else { return nil }
        return store.tasks.selected(in: snapshot)?.id
    }

    /// The open project's own inbox, then its Scheduled tasks.
    @ViewBuilder private func projectContent(inbox: InboxModel) -> some View {
        inboxHeader
        if store.threads.syncing {
            BusyLine("Syncing with GitHub…").padding(.horizontal, Space.s).padding(.vertical, Space.xs)
        }
        if inbox.listed.isEmpty && inbox.composing == nil && inbox.finishedCount == 0 {
            EmptyNote(store.project == nil ? "Choose a project to see its threads." : "No threads yet.", size: .small)
        } else {
            InboxView(store: store, model: inbox)
        }
    }

    /// The list the top tile shows: every project's inbox, under a header that says whose it is.
    @ViewBuilder private var allProjectsContent: some View {
        let model = store.allInboxModel()
        header("INBOX · ALL PROJECTS")
        if model.isEmpty {
            EmptyNote("Nothing in any project yet.", size: .small)
        } else {
            AllInboxView(store: store, model: model)
        }
    }

    /// `INBOX · PROJECT` with the way to a new goal and to the project's agents (the run role's name is its tooltip).
    private var inboxHeader: some View {
        header("INBOX · " + (store.project?.root.lastPathComponent.uppercased() ?? "")) {
            if store.mode == .thread {
                let help = AgentSetup.runLabel(store.agentSetup)
                IconButton.raised("cpu", "Agents", help: help, size: .small) { store.showAgents() }
                    .disabled(store.project == nil)
            }
            IconButton.raised("plus", "New goal", help: "New goal…", size: .small) { store.beginNewGoal() }
                .disabled(store.project == nil)
        }
    }

    private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack {
            Text(title).textStyle(.captionStrong, .secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, Space.s).padding(.bottom, Space.xs)
    }
}
