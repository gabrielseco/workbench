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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if let said = store.tasks.runSaid, store.tasks.runningProject == store.project?.root.path {
                        BusyBar(text: said)
                    }
                    HStack(alignment: .top, spacing: Space.m) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(entry.summary.name).textStyle(.section).lineLimit(1).truncationMode(.middle)
                            Text(header.line).role(.detail).lineLimit(2)
                            Text("Defined in \(header.path). Edit that file, or use Edit with AI.")
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
                    if store.tasks.isEditShown(entry.id, in: store.project) {
                        TaskEditCard(store: store, entry: entry).id(Self.editCardID(entry.id))
                    }
                    if entry.runs.isEmpty {
                        Text("Never run. It runs at the next tick, or by hand: workbench task run \(entry.summary.name)")
                            .role(.detail).textSelection(.enabled)
                    }
                    ForEach(Array(RunDay.groups(runs: entry.runs, now: snapshot.readAt).enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.heading).textStyle(.captionStrong, .secondary).padding(.bottom, Space.s)
                            ForEach(Array(group.runs.enumerated()), id: \.offset) { _, run in
                                Divider()
                                TaskRunRow(
                                    run: run, threadKnown: threadKnown(run.thread), reportExists: reportExists,
                                    detail: store.tasks.detail(store.project, entry.id, run),
                                    isOpen: store.tasks.isOpen(store.project, entry.id, run),
                                    toggle: { Task { await store.tasks.toggleRun(store.project, entry.id, run) } },
                                    fix: run.outcome == nil ? nil : { fixThis(run) },
                                    fixOff: store.tasks.fixUnavailable(entry.id, in: store.project), perform: perform)
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
            // Fix this opened the card below the runs: show the box the person is to answer.
            .task(id: store.tasks.editFocus) {
                guard store.tasks.editFocus > 0 else { return }
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo(Self.editCardID(entry.id), anchor: .center)
            }
        }
    }

    static func editCardID(_ task: String) -> String { "edit-card-\(task)" }

    private func fixThis(_ run: TaskHistory.Run) {
        store.tasks.fixThis(store.project, entry.id, run, detail: store.tasks.detail(store.project, entry.id, run))
    }

    /// A run's thread is one the window can show: its folder is still there (cleaned ones are not), however old it is.
    private func threadKnown(_ id: String?) -> Bool {
        guard let id, let project = store.project else { return false }
        return ThreadStore(project: project).threadIDs().contains(id)
    }

    /// A report the run named is still on disk: one that was moved or deleted has nothing to open.
    private func reportExists(_ path: String) -> Bool {
        guard let project = store.project else { return false }
        return FileManager.default.fileExists(atPath: project.root.appendingPathComponent(path).path)
    }

    private func perform(_ action: RunAction) {
        switch action {
        case .viewLog:
            guard let project = store.project else { return }
            NSWorkspace.shared.activateFileViewerSelecting([TaskRunLog(project: project, name: entry.id).url])
        case .approve, .reapprove: Task { await store.tasks.approve(store.project, entry.id) }
        case .openThread(let id): Task { await store.select(thread: id) }
        case .openLog(let path): NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
                        if let action = Self.action(for: warning), Self.offered(action) {
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

    /// A log that is gone has nothing to open: its path stays text.
    static func offered(_ action: RunAction) -> Bool {
        if case .openLog(let path) = action { return FileManager.default.fileExists(atPath: path) }
        return true
    }

    /// The button for a warning: approval, the active thread, or the tick log.
    static func action(for warning: RunTonight.Warning) -> RunAction? {
        switch warning.action {
        case .approve?: .approve
        case .reapprove?: .reapprove
        case .openThread(let id)?: .openThread(id)
        case .openLog(let path)?: .openLog(path)
        case nil: nil
        }
    }
}

/// One run: a mark, what happened, and at the right the one button that deals with how it ended.
struct TaskRunRow: View {
    var run: TaskHistory.Run
    var threadKnown: Bool
    var reportExists: (String) -> Bool = { _ in true }
    /// What the run did, once its row has been opened and read.
    var detail: TaskRunDetail?
    var isOpen = false
    var toggle: () -> Void = {}
    /// Opens the edit card with this run in its box; nil for a run that has not ended.
    var fix: (() -> Void)?
    /// Why it cannot be pressed now, nil when it can.
    var fixOff: String?
    var perform: (RunAction) -> Void

    var body: some View {
        let tone = TaskOutcomeStyle.tone(run.outcome)
        let action = RunAction.of(run, reportExists: reportExists)
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
                DisclosureToggle(label: "Details", isOpen: isOpen, toggle: toggle).padding(.top, Space.xs)
                if isOpen {
                    if let detail {
                        RunDetailView(facts: RunDetailFacts.make(detail, running: run.outcome == nil)).padding(.top, Space.xs)
                    } else {
                        ProgressView().controlSize(.small).padding(.top, Space.xs)
                    }
                    if let fix {
                        Button("Fix this with AI", action: fix).plainButton(size: .compact).disabled(fixOff != nil)
                            .help(fixOff ?? "Opens Edit with AI with this run's facts; nothing is asked until you propose")
                            .padding(.top, Space.xs)
                    }
                }
            }
            Spacer(minLength: 8)
            if let action, !(action.isThread && !threadKnown) {
                Button(action.title) { perform(action) }.plainButton().controlSize(.small)
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
