import SwiftUI
import WorkbenchCore

/// The latest turn: what the agent is doing, what it has done, what it has cost, and the way to stop it.
struct RunView: View {
    var snapshot: ThreadSnapshot
    var run: RunModel
    var store: ProjectStore

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", edits = "Edits", denied = "Denied"
        var id: String { rawValue }
    }

    @State private var filter = Filter.all

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(now: context.date)
                    card(now: context.date)
                    activity
                    HStack(alignment: .top, spacing: 24) {
                        budget
                        soFar
                    }
                    actions
                }
                .padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.header(now: now)).font(.title2.weight(.semibold))
            Text("isolated worktree").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch run.phase {
            case .working, .checking:
                Label(run.phase == .checking ? "Running the check" : "Working", systemImage: "circle.dotted")
                    .foregroundStyle(Theme.blue)
                if let latest = run.latest { Text(latest).font(.callout) }
                if let quiet = run.quiet(now: now) {
                    Text("quiet for \(Progress.duration(quiet))").font(.callout).foregroundStyle(.secondary)
                }
            case .orphaned:
                Label("The runner for this turn is gone", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.red)
                Text("Run again records it as interrupted and goes on. The log is intact.").font(.callout)
            case .ended(let result, let reason):
                Label(endTitle(result), systemImage: result == "succeeded" ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result == "succeeded" ? Theme.green : Theme.red)
                if let reason { Text(reason).font(.callout) }
                Text("Review comes next.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.grey.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func endTitle(_ result: String) -> String {
        switch result {
        case "succeeded": "Turn ended"
        case "timed_out": "Timed out"
        case "budget_exceeded": "Over budget"
        default: result.capitalized
        }
    }

    private var rows: [RunModel.Row] {
        switch filter {
        case .all: run.rows
        case .edits: run.rows.filter { $0.kind == .edit }
        case .denied: run.rows.filter { $0.kind == .denied }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ACTIVITY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                SwiftUI.Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            if rows.isEmpty {
                Text(filter == .all ? "Nothing yet." : "None.").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        Text(row.text).font(.system(.callout, design: .monospaced))
                            .foregroundStyle(color(row.kind)).lineLimit(2)
                    }
                }
            }
        }
    }

    private func color(_ kind: RunModel.Kind) -> Color {
        switch kind {
        case .denied: Theme.amber
        case .gap, .note: Theme.grey
        default: Color.primary
        }
    }

    private var budget: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BUDGET").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(run.budget.map { "\(run.spent) of \($0)" } ?? run.spent).font(.system(.body, design: .monospaced))
            if let fraction = run.fraction { ProgressView(value: fraction).frame(width: 160) }
            Text(run.turnLimit).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var soFar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SO FAR").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Files changed: \(count(run.filesChanged))")
            Text("Tests: \(run.tests)")
            Text("Denied calls: \(count(run.deniedCalls))")
        }
        .font(.callout)
    }

    private func count(_ value: Int?) -> String { value.map(String.init) ?? "unknown" }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Open worktree") { Task { await store.openWorktree() } }
                if canRunAgain { Button("Run again") { Task { await store.runAgain() } } }
                Spacer()
                if run.phase == .working || run.phase == .checking {
                    Button(store.stopping ? "Stopping…" : "Stop turn") { Task { await store.stopTurn() } }
                        .disabled(store.stopping)
                }
            }
            if run.phase == .working || run.phase == .checking {
                Text("You can close the window.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
        }
    }

    private var canRunAgain: Bool {
        guard snapshot.state.decision == nil, !store.runningHere else { return false }
        switch run.phase {
        case .orphaned: return true
        case .ended(let result, _): return result != "succeeded"
        default: return false
        }
    }
}
