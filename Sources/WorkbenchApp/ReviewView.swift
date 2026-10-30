import SwiftUI
import WorkbenchCore

/// The turn's work, as core reports it, and the three decisions. Nothing on this screen marks a criterion as met.
struct ReviewView: View {
    var review: ReviewModel
    var finishedAt: Date?
    var store: ProjectStore

    @State private var diffPath: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Review · \(headline(now: context.date))").font(.title2.weight(.semibold))
                }
                advice
                criteria
                files
                if !review.commits.isEmpty { section("Commits") { ForEach(review.commits, id: \.self) { mono($0) } } }
                section("Check") { Text(review.check).font(.callout) }
                denied
                due
                if !review.notes.isEmpty {
                    section("Sent back") { ForEach(review.notes, id: \.self) { Text($0).font(.callout) } }
                }
                actions
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshReview() }
        }
        .sheet(item: Binding(get: { diffPath.map(DiffTarget.init) }, set: { diffPath = $0?.path })) { target in
            DiffSheet(store: store, path: target.path)
        }
        .sheet(isPresented: Binding(get: { store.pendingAccept != nil }, set: { if !$0 { store.cancelAccept() } })) {
            AcceptSheet(store: store, undecided: review.undecided)
        }
        .sheet(isPresented: Binding(get: { store.pendingDiscard != nil }, set: { if !$0 { store.cancelDiscard() } })) {
            DiscardSheet(store: store)
        }
    }

    private func headline(now: Date) -> String {
        var parts = [review.headline]
        if let finishedAt { parts[0] += " finished \(Progress.duration(max(0, now.timeIntervalSince(finishedAt)))) ago" }
        if !review.totals.isEmpty { parts.append(review.totals) }
        return parts.joined(separator: " · ")
    }

    private var criteria: some View {
        section("Criteria") {
            if let problem = review.goalProblem {
                Label("The goal file is not valid, so the criteria are unknown: \(problem)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Theme.red).font(.callout)
            } else {
                Text("\(review.assessed) · \(review.criteriaSummary)").font(.callout).foregroundStyle(.secondary)
                ForEach(review.criteria) { criterion in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(criterion.id).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                            Text(criterion.text)
                            Spacer()
                            Text(criterion.label).font(.callout).foregroundStyle(color(criterion))
                        }
                        Text(criterion.proof).font(.callout).foregroundStyle(.secondary)
                        if let note = criterion.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        ForEach(criterion.evidence, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                    }
                }
            }
        }
    }

    private func color(_ criterion: ReviewModel.Criterion) -> Color {
        if criterion.failed { return Theme.red }
        return criterion.forYou ? Theme.amber : Theme.green
    }

    private var files: some View {
        section("Changed files") {
            if let problem = review.diffProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.red).font(.callout)
            } else if review.files.isEmpty {
                Text("No changes.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(review.files) { file in
                Button { diffPath = file.path } label: { mono(file.text) }.buttonStyle(.plain)
                    .help("View diff")
            }
            if let note = review.filesNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// While this app's run goes on after the turn ended, what is running is the advice `[review] auto` asks for: say so, and let
    /// it be stopped from the screen that is showing (the Run screen, which has the other Stop, is not).
    @ViewBuilder private var advice: some View {
        if store.runningHere {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Running the advice the project's config asks for (judge, review stages)…").font(.callout)
                Spacer()
                Button(store.stopping ? "Stopping…" : "Stop advice") { Task { await store.stopTurn() } }
                    .disabled(store.stopping)
            }
        }
    }

    @ViewBuilder private var due: some View {
        if !review.due.isEmpty {
            section("Still due") {
                ForEach(review.due) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        mono(item.command).textSelection(.enabled)
                        Text(item.why).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Run these in a terminal. None of them blocks Accept.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var denied: some View {
        if !review.denied.isEmpty {
            section("Denied calls") {
                ForEach(review.denied) { item in
                    Text("\(item.text) ×\(item.count)")
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.amber)
                }
                Text("Allow one in a terminal with `workbench grant`, then send the work back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Discard…") { Task { await store.prepareDiscard() } }.disabled(store.busy != nil)
                Button("Open worktree") { Task { await store.openWorktree() } }.disabled(store.busy != nil)
                Button("Open diff") { Task { await store.openDiff() } }.disabled(store.busy != nil || review.files.isEmpty)
                    .help("Each changed file against the base, in your editor")
                Button("Refresh") { Task { await store.refreshReview() } }
                    .help("Read the worktree again after editing it")
                Spacer()
                Button("Send back…") { store.sendingBack = true }.disabled(store.busy != nil)
                Button("Accept work") { Task { await store.prepareAccept() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!review.canDecide || store.deciding || store.busy != nil)
            }
            if review.undecided > 0 {
                let verb = review.undecided == 1 ? "criterion is" : "criteria are"
                Text("\(review.undecided) \(verb) for you to check. Accept does not wait.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
            if let note = store.actionNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(.callout, design: .monospaced)).lineLimit(2)
    }
}

private struct DiffTarget: Identifiable {
    var path: String
    var id: String { path }
}

struct DiffSheet: View {
    var store: ProjectStore
    var path: String
    @State private var text = "Reading…"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(path).font(.headline)
                Spacer()
                Button("Open in editor") { Task { await store.openDiff(path: path) } }.disabled(store.busy != nil)
                Button("Close") { dismiss() }
            }
            // The sheet covers the Review screen, where these are shown otherwise.
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
            if let note = store.actionNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20).frame(width: 760, height: 520)
        .task { text = await store.patchText(path) }
    }
}

struct AcceptSheet: View {
    var store: ProjectStore
    var undecided: Int
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accept work").font(.headline)
            if let plan = store.pendingAccept {
                ScrollView {
                    Text(plan.render().joined(separator: "\n")).font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
                if plan.checkFailed {
                    Label("The check did not pass, or a turn was cut off.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.amber).font(.callout)
                }
                if undecided > 0 {
                    let verb = undecided == 1 ? "criterion is" : "criteria are"
                    Text("\(undecided) \(verb) for you to check.").font(.callout).foregroundStyle(.secondary)
                }
                TextField("Commit message", text: $message, prompt: Text(plan.defaultMessage)).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.cancelAccept() }
                Button("Accept") {
                    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await store.confirmAccept(message: text.isEmpty ? nil : text) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 560)
    }
}

struct DiscardSheet: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Discard this work").font(.headline)
            if let plan = store.pendingDiscard {
                ScrollView {
                    Text(plan.render().joined(separator: "\n")).font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
                if !plan.fullyShown {
                    Text("Not everything that would be lost could be listed.").font(.callout).foregroundStyle(Theme.amber)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { store.cancelDiscard() }
                Button("Discard", role: .destructive) { Task { await store.confirmDiscard() } }
            }
        }
        .padding(20).frame(width: 560)
    }
}
