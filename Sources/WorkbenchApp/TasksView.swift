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

/// The rail while the Tasks screen is shown: what the list says in one line, so the rail is not a blank.
struct TasksRailSummary: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TASKS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let snapshot = store.tasks.snapshot(for: store.project) {
                let broken = snapshot.entries.filter { TaskOutcomeStyle.tone($0.runs.first?.outcome) == .broken }.count
                Text(snapshot.entries.count == 1 ? "1 task" : "\(snapshot.entries.count) tasks").font(.headline)
                if broken > 0 {
                    Label("\(broken) did not end well", systemImage: "xmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.red)
                }
            } else {
                Text("Reading…").font(.headline).foregroundStyle(.secondary)
            }
            Text("Scheduled work, read from .workbench/tasks. Nothing here changes a task.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
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
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                TimerCardView(card: snapshot.timer)
                                TaskList(store: store, snapshot: snapshot)
                            }
                            .padding(14)
                        }
                        .frame(width: 300)
                        Divider()
                        if let entry = store.tasks.selected(in: snapshot) {
                            Timeline(store: store, entry: entry, now: snapshot.readAt)
                        }
                    }
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
                    VStack(alignment: .leading, spacing: 1) {
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

struct TaskList: View {
    var store: ProjectStore
    var snapshot: TasksSnapshot

    var body: some View {
        let selected = store.tasks.selected(in: snapshot)?.id
        VStack(alignment: .leading, spacing: 4) {
            Text("Tasks").font(.headline).padding(.bottom, 2)
            ForEach(snapshot.entries) { entry in
                Button {
                    store.tasks.selection = entry.id
                } label: {
                    TaskRow(entry: entry, now: snapshot.readAt)
                        .padding(8)
                        .background(
                            selected == entry.id ? Theme.blue.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct TaskRow: View {
    var entry: TaskEntry
    var now: Date

    var body: some View {
        let summary = entry.summary
        let outcome = entry.runs.first?.outcome
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if !entry.runs.isEmpty {
                    Image(systemName: TaskOutcomeStyle.symbol(outcome))
                        .foregroundStyle(Theme.color(for: TaskOutcomeStyle.tone(outcome)))
                } else {
                    Image(systemName: "circle").foregroundStyle(Theme.grey)
                }
                Text(summary.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(TaskOutcomeStyle.approvalWord(summary)).font(.caption)
                    .foregroundStyle(Theme.color(for: TaskOutcomeStyle.approvalTone(summary)))
            }
            Text(summary.schedule ?? "manual").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                Text(entry.runs.isEmpty ? "never run" : "last: \(TaskOutcomeStyle.word(outcome))")
                Text("·")
                Text("next: \(TasksText.next(summary, now: now))")
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let problem = summary.problem {
                Text(TaskExplanation.clean(problem, limit: 160)).font(.caption).foregroundStyle(Theme.red).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The runs of the selected task, newest first, each with the reason it ended as it did.
struct Timeline: View {
    var store: ProjectStore
    var entry: TaskEntry
    var now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.summary.name).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(
                    "\(entry.summary.schedule ?? "manual") · \(entry.summary.fix.map { "fix: \($0.rawValue)" } ?? "—") · "
                        + "\(entry.runs.count) run\(entry.runs.count == 1 ? "" : "s")"
                )
                .font(.caption).foregroundStyle(.secondary)
                if let problem = entry.summary.problem {
                    Label(TaskExplanation.clean(problem, limit: 400), systemImage: "xmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.red).textSelection(.enabled)
                } else if entry.summary.approval == .stale {
                    Label(
                        "Edited since it was approved: it will not run until approved again.",
                        systemImage: "exclamationmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.amber)
                    Text("workbench task approve \(entry.summary.name)")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } else if entry.summary.approval == .never {
                    Label("Not approved: nothing runs unapproved.", systemImage: "exclamationmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.amber)
                    Text("workbench task approve \(entry.summary.name)")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Divider()
                if entry.runs.isEmpty {
                    Text("Never run. It runs at the next tick, or by hand: workbench task run \(entry.summary.name)")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(Array(entry.runs.enumerated()), id: \.offset) { _, run in
                    RunRow(store: store, run: run, now: now)
                    Divider()
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RunRow: View {
    var store: ProjectStore
    var run: TaskHistory.Run
    var now: Date

    /// The thread is one the window can show: it is the one on screen. The window has no thread list yet, so any other is an id to copy.
    private var canOpenThread: Bool { TasksText.canOpenThread(run, onScreen: store.currentThread) }

    var body: some View {
        let tone = TaskOutcomeStyle.tone(run.outcome)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: TaskOutcomeStyle.symbol(run.outcome)).foregroundStyle(Theme.color(for: tone)).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(TaskOutcomeStyle.word(run.outcome)).font(.callout.weight(.semibold))
                        .foregroundStyle(tone == .broken || tone == .needsYou ? Theme.color(for: tone) : Color.primary)
                    Text(TasksText.when(run.started, now: now)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(run.trigger).font(.caption).foregroundStyle(.secondary)
                }
                if !run.units.isEmpty {
                    Text(run.units.joined(separator: ", ")).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                }
                if let reason = TasksText.reason(run) {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        .help(reason)
                }
                if let pr = run.pullRequest {
                    Text(pr).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let thread = run.thread {
                    if canOpenThread {
                        Button("Open thread \(thread)") { store.mode = .thread }
                            .buttonStyle(.link).font(.caption)
                    } else {
                        Text("thread \(thread)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
