import AppKit
import SwiftUI
import WorkbenchCore

/// A task as a page (design parity 5), in the feed's column: its header, its own *Will it run tonight?* card and its runs by day.
struct TaskPageView: View {
    var store: ProjectStore
    var snapshot: TasksSnapshot
    var entry: TaskEntry

    var body: some View {
        let header = TaskPage.header(entry, now: snapshot.readAt)
        let tonight = RunTonight.derive(entry, timer: snapshot.timer, activeThread: snapshot.activeThread)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if let said = store.tasks.runSaid, store.tasks.runningProject == store.project?.root.path { BusyBar(text: said) }
                HStack(alignment: .top, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(entry.summary.name).textStyle(.section).lineLimit(1).truncationMode(.middle)
                        Text(header.line).role(.detail).lineLimit(2)
                        Text("Defined in \(header.path). Edit that file to change it.")
                            .textStyle(.mono, .subtle).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    TaskButtons(store: store, entry: entry)
                }
                if let note = store.tasks.actionNote {
                    Text(note).role(.caption).textSelection(.enabled)
                }
                if let result = store.tasks.result(of: entry.id, in: store.project) { ResultLine(result: result) }
                RunTonightCard(tonight: tonight, perform: perform).id(entry.id)
                if entry.runs.isEmpty {
                    Text("Never run. It runs at the next tick, or by hand: workbench task run \(entry.summary.name)")
                        .role(.detail).textSelection(.enabled)
                }
                ForEach(Array(RunDay.groups(runs: entry.runs, now: snapshot.readAt).enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.heading).textStyle(.captionStrong, .secondary).padding(.bottom, Space.s)
                        ForEach(Array(group.runs.enumerated()), id: \.offset) { _, run in
                            Divider()
                            TaskRunRow(run: run, threadKnown: threadKnown(run.thread), perform: perform)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxWidth: FeedLayout.maxColumn, alignment: .leading)
            .padding(.horizontal, Spacing.gutter).padding(.vertical, Space.xl).frame(maxWidth: .infinity)
        }
        // Looking at a task is seeing what broke in it: its items stop counting, and a newer failure counts again.
        .task(id: "\(entry.id)|\(store.attention.items.map(\.id))") { store.attention.markSeen(shown: entry) }
    }

    /// A run's thread is one the window can show: its folder is still there (cleaned ones are not), however old it is.
    private func threadKnown(_ id: String?) -> Bool {
        guard let id, let project = store.project else { return false }
        return ThreadStore(project: project).threadIDs().contains(id)
    }

    private func perform(_ action: RunAction) {
        switch action {
        case .viewLog:
            guard let project = store.project else { return }
            NSWorkspace.shared.activateFileViewerSelecting([TaskRunLog(project: project, name: entry.id).url])
        case .approve, .reapprove: store.tasks.beginApprove(store.project, entry.id)
        case .openThread(let id): Task { await store.select(thread: id) }
        case .openReport(let path):
            guard let project = store.project else { return }
            NSWorkspace.shared.open(project.root.appendingPathComponent(path))
        }
    }
}

/// The task's own *Will it run tonight?*: a verdict and, open by default when there is something to read, its warnings with the one button
/// that deals with each.
struct RunTonightCard: View {
    var tonight: RunTonight
    var perform: (RunAction) -> Void
    @State private var expanded: Bool?

    private var open: Bool { expanded ?? tonight.openByDefault }

    private var tint: Color {
        switch tonight.verdict {
        case .willRun: Theme.green
        case .checkWarnings: Theme.amber
        case .willNotRun: Theme.red
        }
    }

    private var symbol: String {
        switch tonight.verdict {
        case .willRun: "checkmark.circle.fill"
        case .checkWarnings: "exclamationmark.circle.fill"
        case .willNotRun: "xmark.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded = !open
            } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: symbol).foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("WILL IT RUN TONIGHT?").textStyle(.captionStrong).tracking(0.6).foregroundStyle(.secondary)
                        Text(tonight.verdict.text).textStyle(.calloutStrong)
                    }
                    Spacer()
                    if let count = tonight.countText { Text(count).role(.caption) }
                    if !tonight.warnings.isEmpty {
                        Image(systemName: open ? "chevron.up" : "chevron.down").textStyle(.captionMedium, .secondary)
                    }
                }
                .padding(Space.m).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Will it run tonight? \(tonight.verdict.text)\(tonight.countText.map { ", \($0)" } ?? "")")
            if open {
                ForEach(Array(tonight.warnings.enumerated()), id: \.offset) { _, warning in
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(warning.text).textStyle(.callout)
                            if let detail = warning.detail {
                                Text(detail).role(.mono)
                                    .lineLimit(2).textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 8)
                        if let action = Self.action(for: warning) {
                            Button(action.title) { perform(action) }.plainButton().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .card(stroke: tonight.verdict == .willRun ? Theme.line : tint.opacity(0.45))
    }

    /// The button for a warning: approval, or the active thread.
    static func action(for warning: RunTonight.Warning) -> RunAction? {
        switch warning.action {
        case .approve?: .approve
        case .reapprove?: .reapprove
        case .openThread(let id)?: .openThread(id)
        case nil: nil
        }
    }
}

/// One run: a mark, what happened, and at the right the one button that deals with how it ended.
struct TaskRunRow: View {
    var run: TaskHistory.Run
    var threadKnown: Bool
    var perform: (RunAction) -> Void

    var body: some View {
        let tone = TaskOutcomeStyle.tone(run.outcome)
        let action = RunAction.of(run)
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: TaskOutcomeStyle.symbol(run.outcome)).foregroundStyle(Theme.color(for: tone)).frame(width: 16)
                .padding(.top, Space.xxs)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    Text(TaskOutcomeStyle.word(run.outcome)).textStyle(.calloutStrong)
                        .foregroundStyle(tone == .broken || tone == .needsYou ? Theme.color(for: tone) : Color.primary)
                    Text(run.started.formatted(.dateTime.hour().minute()))
                        .role(.caption).monospacedDigit()
                    Text(run.trigger).role(.caption)
                }
                // Not selectable: a selected line-limited Text grows past its row and paints over the next one; the full text is the help.
                if let reason = TasksText.reason(run) {
                    Text(reason).role(.caption).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true).help(reason)
                }
                if !run.units.isEmpty {
                    Text(run.units.joined(separator: ", ")).textStyle(.mono)
                        .foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                }
                if let pr = run.pullRequest {
                    Text(pr).textStyle(.mono).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                // A thread the rail does not list (cleaned, or older than the list) is an id to copy.
                if let thread = run.thread, !(threadKnown && action == .openThread(thread)) {
                    Text("thread \(thread)").role(.mono)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let action, !(action.isThread && !threadKnown) {
                Button(action.title) { perform(action) }.plainButton().controlSize(.small)
            }
            // A report run has no thread: its log is how to see what really happened.
            if case .openReport = action {
                Button(RunAction.viewLog.title) { perform(.viewLog) }.plainButton().controlSize(.small)
            }
        }
        .padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension RunAction {
    var isThread: Bool {
        if case .openThread = self { return true }
        return false
    }
}
