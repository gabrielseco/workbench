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
                Rail(store: store).frame(width: 220).background(Theme.rail)
                Divider()
                Centre(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            FooterBar(store: store)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

/// The project pill, the base, the state pill and the spend meter.
struct ToolbarBar: View {
    var store: ProjectStore

    /// What the project pill is called to assistive technology, and so to scripts/verify-app.sh: it opens a file panel, and its
    /// refusal list matches this label's start, which the folder's name alone would not.
    static func projectButtonLabel(_ project: Project?) -> String {
        "Choose project" + (project.map { ", now \($0.root.lastPathComponent)" } ?? "")
    }

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(store.recentProjects()) { entry in
                    Button {
                        Task { await store.switchTo(entry.path) }
                    } label: {
                        let flag = entry.unavailable == nil ? "" : " · unavailable"
                        Label(
                            entry.name + (entry.isRunning ? " · running" : "") + flag,
                            systemImage: entry.isCurrent ? "checkmark" : "folder")
                    }
                    .disabled(entry.unavailable != nil)
                    .help(entry.unavailable ?? entry.path)
                }
                ForEach(store.recentProjects().filter { $0.unavailable != nil }) { entry in
                    Button("Remove \(entry.name) from the list") { store.forget(entry.path) }
                }
                Divider()
                Button("Choose folder…") { Picker.chooseProject(store) }
            } label: {
                HStack(spacing: 4) {
                    Text(store.project?.root.lastPathComponent ?? "Choose project")
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(ToolbarBar.projectButtonLabel(store.project))
            if case .thread(let snapshot) = store.screen {
                if let base = snapshot.base { Text("base: \(base)").font(.system(.callout, design: .monospaced)) }
                Spacer()
                Text(snapshot.spendText).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                StatePill(snapshot: snapshot)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct StatePill: View {
    var snapshot: ThreadSnapshot

    var body: some View {
        let tint: Color = {
            if case .needsYou = snapshot.attention { return Theme.amber }
            if snapshot.attention == .working { return Theme.blue }
            return Theme.grey
        }()
        Text(snapshot.stateText)
            .font(.callout).padding(.horizontal, 10).padding(.vertical, 3)
            .foregroundStyle(tint).background(tint.opacity(0.12), in: Capsule())
    }
}

struct Rail: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading) {
            if case .thread(let snapshot) = store.screen {
                SpineRail(snapshot: snapshot)
            } else {
                Text("THREAD").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("None").font(.headline)
            }
            Spacer()
            DoctorButton(store: store)
        }
        .padding(16)
    }
}

struct DoctorButton: View {
    var store: ProjectStore

    var body: some View {
        Button {
            Task { await store.runDoctor() }
        } label: {
            HStack {
                Text("Doctor")
                Spacer()
                switch store.doctor {
                case .notRun: Text("Not run").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .healthy(let seconds):
                    Text(String(format: "Healthy · %.1fs", seconds)).foregroundStyle(Theme.green)
                case .problem: Text("Problem").foregroundStyle(Theme.red)
                }
            }
            .padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.grey.opacity(0.4)))
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
        if case .thread(let snapshot) = store.screen {
            ThreadPane(snapshot: snapshot, goal: store.goal, store: store)
        } else if let message = store.screen.message {
            EmptyState(title: message.title, next: message.next, store: store)
        }
    }
}

struct ThreadPane: View {
    var snapshot: ThreadSnapshot
    var goal: GoalModel?
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let busy = store.busy { BusyBar(text: busy) }
            if goal == nil {
                Text(snapshot.title ?? snapshot.id).font(.title.weight(.bold))
                Text(".workbench/threads/\(snapshot.id)/goal.md")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Text(snapshot.stateText).font(.title3).foregroundStyle(.secondary).padding(.top, 4)
            }
            if !snapshot.problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("The log has damaged lines; this shows what could be read.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Theme.red)
                    ForEach(snapshot.problems, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    Text("Open the event log to see it; Workbench never rewrites it.").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            if case .needsYou(let reason) = snapshot.attention, store.review == nil {
                Label(reason.text, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.amber).padding(.top, 8)
            }
            if let notice = store.notice { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green) }
            if let finished = snapshot.finishedText {
                FinishedBanner(snapshot: snapshot, text: finished, store: store)
            }
            if let review = store.review {
                ReviewView(review: review, finishedAt: snapshot.run?.endedAt, store: store)
            } else if let run = snapshot.run {
                RunView(snapshot: snapshot, run: run, store: store)
            } else if let goal {
                GoalView(snapshot: snapshot, goal: goal, store: store)
            }
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the app is doing for the person right now: a click is answered at once, even when the work behind it takes a while.
struct BusyBar: View {
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.grey.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// How a decided thread ended, and the way to the next goal: the one active thread is over, so a new one may start.
struct FinishedBanner: View {
    var snapshot: ThreadSnapshot
    var text: String
    var store: ProjectStore
    @State private var naming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let url = snapshot.pullRequestURL {
                    Link(destination: url) { Label(text, systemImage: "flag.checkered") }
                        .help("Opens \(url.absoluteString) in the browser")
                } else {
                    Label(text, systemImage: "flag.checkered").foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.canShip { Button("Ship…") { Task { await store.prepareShip() } }.disabled(store.busy != nil) }
                if snapshot.canReviewPullRequest {
                    Button(snapshot.state.review.prReview == nil ? "Review PR" : "Review again") {
                        Task { await store.reviewPullRequest() }
                    }
                    .disabled(store.busy != nil).help("Codex reads the pull request, read-only, and says what it found")
                }
                Button("New goal…") { naming = true }
            }
            if let line = snapshot.prReviewText {
                HStack {
                    Text(line).font(.callout).foregroundStyle(.secondary)
                    Button("Show findings") { Task { await store.showPRReview() } }.buttonStyle(.link)
                }
            }
            if let note = snapshot.newGoalNote { Text(note).font(.callout).foregroundStyle(.secondary) }
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
        }
        .padding(12).background(Theme.grey.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $naming) { NewGoalSheet(store: store, shown: $naming) }
        .sheet(isPresented: Binding(get: { store.prReviewShown != nil }, set: { if !$0 { store.closePRReview() } })) {
            PRReviewSheet(store: store)
        }
        .sheet(isPresented: Binding(get: { store.pendingShip != nil }, set: { if !$0 { store.cancelShip() } })) {
            ShipSheet(store: store)
        }
    }
}

struct EmptyState: View {
    var title: String
    var next: String
    var store: ProjectStore
    @State private var naming = false

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.title2.weight(.semibold))
            Text(next).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Choose project…") { Picker.chooseProject(store) }
                if store.screen == .noThread { Button("New goal…") { naming = true } }
            }
            .padding(.top, 6)
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
        }
        .padding(40)
        .sheet(isPresented: $naming) { NewGoalSheet(store: store, shown: $naming) }
    }
}

struct FooterBar: View {
    var store: ProjectStore

    var body: some View {
        HStack {
            if let url = store.logURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(label).foregroundStyle(Theme.blue)
                }
                .buttonStyle(.plain)
                .help("Opens the raw log file")
            } else {
                Text("Nothing is running.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var label: String {
        if case .thread(let snapshot) = store.screen { return "Event log \(snapshot.lastSeq)" }
        return "Open the event log"
    }
}

enum Picker {
    @MainActor static func chooseProject(_ store: ProjectStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder of a git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.open(url) }
    }
}
