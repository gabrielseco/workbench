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
        // The popover is modal as the sheet was: what is behind it takes no click and no Tab until it closes.
        .disabled(store.namingGoal || store.sendingBack || store.pickingProject)
        .frame(minWidth: 900, minHeight: 600)
        .overlay(alignment: .topLeading) { ProjectPickerLayer(store: store) }
        .overlay { OverlayLayer(shown: store.namingGoal) { NewGoalPopover(store: store) } }
        .overlay { OverlayLayer(shown: store.sendingBack) { SendBackPopover(store: store) } }
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
        HStack(spacing: 12) {
            ProjectPill(store: store)
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

/// The open project's name with a folder and a chevron; it opens the project card.
struct ProjectPill: View {
    var store: ProjectStore
    @State private var hovered = false

    var body: some View {
        Button {
            store.pickingProject.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.blue)
                Text(store.project?.root.lastPathComponent ?? "Choose project").font(.body.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.grey.opacity(store.pickingProject ? 0.2 : hovered ? 0.14 : 0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovered = $0 }
        .accessibilityLabel(ToolbarBar.projectButtonLabel(store.project))
        .help(store.project?.root.path ?? "Choose a project")
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
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, scrollsItself ? 0 : 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Goal screen is a scroll view with its own padding: no bottom padding here, so it scrolls to the footer and does not
    /// cut its last row off in the middle of the window.
    private var scrollsItself: Bool { store.review == nil && snapshot.run == nil && goal != nil }
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
    @State private var confirmingMerge = false

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
                if snapshot.canShip {
                    Button("Ship") { Task { await store.ship() } }.disabled(store.busy != nil || store.deciding)
                        .help("Pushes the branch and opens or updates its pull request")
                }
                if snapshot.canReviewPullRequest {
                    Button(snapshot.state.review.prReview == nil ? "Review PR" : "Review again") {
                        Task { await store.reviewPullRequest() }
                    }
                    .disabled(store.busy != nil).help("Codex reads the pull request, read-only, and says what it found")
                }
                if snapshot.watchesPullRequest {
                    Button("Merge…") { confirmingMerge = true }
                        .disabled(!snapshot.canMerge || store.busy != nil || store.deciding)
                        .help(snapshot.ci?.mergeBlocker ?? "Squash-merges the pull request on GitHub")
                }
                Button("New goal…") { store.namingGoal = true }
            }
            if snapshot.watchesPullRequest, let ci = snapshot.ci {
                PullRequestCIView(ci: ci, store: store)
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
        .sheet(isPresented: Binding(get: { store.prReviewShown != nil }, set: { if !$0 { store.closePRReview() } })) {
            PRReviewSheet(store: store)
        }
        .confirmationDialog(mergeTitle, isPresented: $confirmingMerge) {
            Button("Merge") { Task { await store.mergePullRequest() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Squash-merges it on GitHub at the commit whose checks are green. This cannot be undone from Workbench.")
        }
    }

    private var mergeTitle: String { snapshot.state.pullRequest.map { "Merge PR #\($0.number)?" } ?? "Merge?" }
}

/// The shipped pull request's CI as GitHub said it last: one line, then one row per check, and why Merge waits when it does.
struct PullRequestCIView: View {
    var ci: PullRequestCI
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label(ci.summary, systemImage: icon).foregroundStyle(color).font(.callout)
                Button("Refresh") { Task { await store.refreshPullRequestCI() } }.buttonStyle(.link).font(.callout)
            }
            // The banner sits outside the scrolling content, so a long list scrolls in its own box instead of pushing the window.
            if ci.rows.count > Self.unscrolledRows {
                ScrollView { rows }.frame(maxHeight: 130)
            } else {
                rows
            }
            if !ci.canMerge, let blocker = ci.mergeBlocker, ci.unavailableReason == nil {
                Text("Merge waits: \(blocker)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    static let unscrolledRows = 6

    private var rows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(ci.rows, id: \.self) { row in
                HStack(spacing: 6) {
                    Image(systemName: rowIcon(row.kind)).foregroundStyle(rowColor(row.kind))
                    Text(row.name).font(.system(.callout, design: .monospaced))
                    Text(row.word).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
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
        VStack(spacing: 10) {
            Text(title).font(.title2.weight(.semibold))
            Text(next).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Choose project…") { Task { await store.chooseFolder() } }
                if store.screen == .noThread { Button("New goal…") { store.namingGoal = true } }
            }
            .padding(.top, 6)
            if let error = store.actionError { Text(error).font(.callout).foregroundStyle(Theme.red) }
        }
        .padding(40)
    }
}

struct FooterBar: View {
    var store: ProjectStore

    var body: some View {
        HStack {
            if let url = store.logURL {
                Button {
                    // A .jsonl may have no app to open it: show it in Finder rather than do nothing.
                    if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: {
                    Label(label, systemImage: "doc.text").foregroundStyle(Theme.blue)
                }
                .buttonStyle(.bordered).controlSize(.small)
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
