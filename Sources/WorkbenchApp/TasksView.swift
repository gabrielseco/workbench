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
                    .font(.callout).foregroundStyle(Theme.red).padding(.horizontal, 20).padding(.vertical, 8)
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
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the tasks…").font(.callout).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("No scheduled tasks").font(.title.weight(.bold))
            Text("A task is work Workbench does on a schedule, with nobody at the keyboard, and hands back as a pull request.")
                .font(.callout).foregroundStyle(.secondary)
            Text("workbench task new <name>").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text("Run it in this project's folder, edit .workbench/tasks/<name>/task.md, then approve it. They show up here.")
                .font(.callout).foregroundStyle(.secondary)
            TimerCardView(card: timer).frame(maxWidth: 420)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "Will it run tonight?": the core's own lines, worst first in the headline.
struct TimerCardView: View {
    var card: TimerCard
    @State private var expanded: Bool?

    private var open: Bool { expanded ?? false }

    var body: some View {
        let tone: TaskTone = card.worst.map(TaskOutcomeStyle.tone) ?? .idle
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded = !open
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: card.worst.map(TaskOutcomeStyle.symbol) ?? "questionmark.circle")
                        .foregroundStyle(Theme.color(for: tone))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Will it run tonight?").font(.caption).foregroundStyle(.secondary)
                        Text(card.headline).font(.callout.weight(.semibold))
                        if let counts = card.counts {
                            Text(counts).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
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
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: TaskOutcomeStyle.symbol(line.level))
                                .foregroundStyle(Theme.color(for: TaskOutcomeStyle.tone(line.level))).font(.caption)
                            Text(line.text).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .unknown(let why):
                    Text("unknown: \(why)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
        HStack(spacing: 8) {
            if tasks.isRunning(entry.id, in: store.project) {
                Button("Stop") { Task { await tasks.stopRun() } }
                    .help("Ends the agent's turn; the run records how it ended")
            } else {
                if needsApproval {
                    Button("Approve…") { tasks.beginApprove(store.project, entry.id) }
                        .primaryButton().disabled(tasks.isRunning)
                        .help("Shows what would run with nobody watching, then records the approval")
                }
                Button("Run now") {
                    Task { await tasks.beginRun(store.project, entry, threadRunGoing: store.runningProjectPath != nil) }
                }
                    .modifier(PrimaryWhen(!needsApproval)).disabled(off != nil).help(off ?? "Runs the task now, as a tick would")
            }
        }
    }
}

struct PrimaryWhen: ViewModifier {
    var primary: Bool
    init(_ primary: Bool) { self.primary = primary }

    func body(content: Content) -> some View {
        if primary { content.primaryButton() } else { content.plainButton() }
    }
}

/// How a run started here ended, in the outcome's own colour: a skip is grey or amber, never a failure.
struct ResultLine: View {
    var result: TaskRunResult

    var body: some View {
        let tone = TaskOutcomeStyle.tone(result.outcome)
        VStack(alignment: .leading, spacing: 3) {
            Label(TaskOutcomeStyle.word(result.outcome), systemImage: TaskOutcomeStyle.symbol(result.outcome))
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.color(for: tone))
            if let reason = result.reason, !reason.isEmpty {
                Text(TaskExplanation.clean(reason, limit: TaskExplanation.maxReason)).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !result.units.isEmpty {
                Text(result.units.joined(separator: ", "))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let thread = result.thread {
                Text("thread \(thread)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let pr = result.pullRequest { Text(pr).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            if !result.recorded { Text("not recorded in the task's run log").font(.caption).foregroundStyle(Theme.amber) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color(for: tone).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
