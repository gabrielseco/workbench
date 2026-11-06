import AppKit
import SwiftUI
import WorkbenchCore

extension Theme {
    static func color(for tone: TaskTone) -> Color {
        switch tone {
        case .done: green
        case .working: blue
        case .idle: grey
        case .needsYou: amber
        case .broken: red
        }
    }
}

struct TasksView: View {
    var store: ProjectStore

    var body: some View {
        let snapshot = store.tasks.snapshot(for: store.project)
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.tasks.error {
                Label("Could not read the tasks: \(error). Showing the last read.", systemImage: "xmark.octagon.fill")
                    .textRole(.error).padding(.horizontal, Space.xl).padding(.vertical, Space.s)
                Divider()
            }
            if let snapshot {
                if snapshot.entries.isEmpty {
                    NoTasks(timer: snapshot.timer)
                } else if let entry = store.tasks.selected(in: snapshot) {
                    // The rail lists the tasks; the main area is the selected task's page (design parity 5).
                    TaskPageView(store: store, snapshot: snapshot, entry: entry)
                }
            } else {
                VStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading the tasks…").role(.detail)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: store.project?.root.path) {
            var first = true
            while !Task.isCancelled {
                await store.tasks.refreshIfDue(store.project, visible: true, force: first)
                first = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.tasks.refreshIfDue(store.project, visible: true, force: true) }
        }
    }
}

/// No task in the project: says where they are made, since the app does not make them.
struct NoTasks: View {
    var timer: TimerCard

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("No scheduled tasks").textStyle(.display)
            Text("A task is work Workbench does on a schedule, with nobody at the keyboard, and hands back as a pull request.")
                .role(.detail)
            Text("workbench task new <name>").textStyle(.monoCallout).textSelection(.enabled)
            Text("Run it in this project's folder, edit .workbench/tasks/<name>/task.md, then approve it. They show up here.")
                .role(.detail)
            TimerCardView(card: timer).frame(maxWidth: 420)
        }
        .padding(Space.xxxl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "Will it run tonight?": the core's own lines, worst first in the headline.
struct TimerCardView: View {
    var card: TimerCard
    @State private var expanded: Bool?

    private var open: Bool { expanded ?? false }

    var body: some View {
        let tone: TaskTone = card.worst.map(TaskOutcomeStyle.tone) ?? .idle
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                expanded = !open
            } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: card.worst.map(TaskOutcomeStyle.symbol) ?? "questionmark.circle")
                        .foregroundStyle(Theme.color(for: tone))
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Will it run tonight?").role(.caption)
                        Text(card.headline).textStyle(.calloutStrong)
                        if let counts = card.counts {
                            Text(counts).role(.caption)
                        }
                    }
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").textStyle(.captionMedium, .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Will it run tonight? \(card.headline)")
            if open {
                Divider()
                switch card {
                case .lines(let lines):
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Image(systemName: TaskOutcomeStyle.symbol(line.level))
                                .foregroundStyle(Theme.color(for: TaskOutcomeStyle.tone(line.level))).textStyle(.caption)
                            Text(line.text).textStyle(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .unknown(let why):
                    Text("unknown: \(why)").role(.caption).textSelection(.enabled)
                }
            }
        }
        .padding(Space.m)
        .callout(.neutral)
    }
}

/// The one primary action for this task's state, and the others quieter: Approve while it is not approved, Run now once it is, Stop
/// while a run started here goes.
struct TaskButtons: View {
    var store: ProjectStore
    var entry: TaskEntry

    var body: some View {
        let tasks = store.tasks
        let needsApproval = entry.summary.problem == nil && entry.summary.approval != .approved
        let off = tasks.runUnavailable(entry, threadRunGoing: store.runningProjectPath != nil)
        HStack(spacing: Space.s) {
            if tasks.isRunning(entry.id, in: store.project) {
                Button("Stop") { Task { await tasks.stopRun() } }
                    .help("Ends the agent's turn; the run records how it ended")
            } else {
                if needsApproval {
                    Button("Approve") { Task { await tasks.approve(store.project, entry.id) } }
                        .primaryButton().disabled(tasks.isRunning)
                        .help("Records the approval: the task then runs on its schedule with nobody watching")
                }
                Button("Run now") {
                    Task { await tasks.beginRun(store.project, entry, threadRunGoing: store.runningProjectPath != nil) }
                }
                    .modifier(PrimaryWhen(!needsApproval)).disabled(off != nil).help(off ?? "Runs the task now, as a tick would")
                let editing = tasks.editing(entry.id, in: store.project) != nil
                Button(tasks.isEditShown(entry.id, in: store.project) && !editing ? "Close edit" : "Edit with AI") {
                    tasks.toggleEdit(entry.id, in: store.project)
                }
                .plainButton(size: .regular).disabled(editing)
                .help(
                    editing
                        ? "An edit is open: accept or discard it first"
                        : "Describe a change to this task in words; you review it before anything is written")
            }
        }
    }
}

struct PrimaryWhen: ViewModifier {
    var primary: Bool
    /// Both kinds in one size, so the primary and the plain button beside it are a pair; nil is each kind's own default.
    var size: ButtonSize?
    init(_ primary: Bool, size: ButtonSize? = nil) { (self.primary, self.size) = (primary, size) }

    func body(content: Content) -> some View {
        if primary { content.primaryButton(size: size ?? .regular) } else { content.plainButton(size: size ?? .compact) }
    }
}

/// How a run started here ended, in the outcome's own colour: a skip is grey or amber, never a failure.
struct ResultLine: View {
    var result: TaskRunResult

    var body: some View {
        let tone = TaskOutcomeStyle.tone(result.outcome)
        VStack(alignment: .leading, spacing: Space.xs) {
            Label(TaskOutcomeStyle.word(result.outcome), systemImage: TaskOutcomeStyle.symbol(result.outcome))
                .textStyle(.calloutStrong).foregroundStyle(Theme.color(for: tone))
            if let reason = result.reason, !reason.isEmpty {
                Text(TaskExplanation.clean(reason, limit: TaskExplanation.maxReason)).role(.caption)
                    .textSelection(.enabled)
            }
            if !result.units.isEmpty {
                Text(result.units.joined(separator: ", "))
                    .role(.mono)
            }
            if let thread = result.thread {
                Text("thread \(thread)").role(.mono)
                    .textSelection(.enabled)
            }
            if let pr = result.pullRequest { Text(pr).textStyle(.mono).textSelection(.enabled) }
            if !result.recorded { Text("not recorded in the task's run log").textStyle(.caption, .amber) }
        }
        .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .callout(.tinted(Theme.color(for: tone)))
        .accessibilityElement(children: .combine)
    }
}
