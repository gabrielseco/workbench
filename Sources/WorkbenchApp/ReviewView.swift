import SwiftUI
import WorkbenchCore

/// The turn's work, as core reports it. Nothing on this screen marks a criterion as met.
struct ReviewView: View {
    var review: ReviewModel
    var finishedAt: Date?
    var store: ProjectStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Review · \(headline(now: context.date))").textStyle(.title)
                }
                advice
                criteria
                files
                if !review.commits.isEmpty { section("Commits") { ForEach(review.commits, id: \.self) { mono($0) } } }
                section("Check") { Text(review.check).textStyle(.callout) }
                denied
                due
                if !review.notes.isEmpty {
                    section("Sent back") { ForEach(review.notes, id: \.self) { Text($0).textStyle(.callout) } }
                }
                actions
            }
            .padding(Space.xxxl).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.loadSendBackGrants() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshReview() }
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
                    .foregroundStyle(Theme.red).textStyle(.callout)
            } else if review.criteria.isEmpty, !review.unavailable.isEmpty {
                Text("None: a quick goal. Check the work against the request.").textStyle(.callout)
                ForEach(review.unavailable, id: \.self) {
                    Text($0).role(.caption).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("\(review.assessed) · \(review.criteriaSummary)").role(.detail)
                ForEach(review.criteria) { criterion in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(criterion.id).role(.monoDetail)
                            Text(criterion.text)
                            Spacer()
                            Text(criterion.label).textStyle(.callout).foregroundStyle(color(criterion))
                        }
                        Text(criterion.proof).role(.detail)
                        if let note = criterion.note { Text(note).role(.caption) }
                        ForEach(criterion.evidence, id: \.self) { Text($0).textStyle(.mono) }
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
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.red).textStyle(.callout)
            } else if review.files.isEmpty {
                Text("No changes.").role(.detail)
            }
            ForEach(review.files) { file in
                Button { store.feedModals.diffPath = file.path } label: { mono(file.text) }.buttonStyle(.plain)
                    .help("View diff")
            }
            if let note = review.filesNote { Text(note).role(.caption) }
        }
    }

    /// While this app's run goes on after the turn ended, what is running is the advice `[review] auto` asks for: say so, and let
    /// it be stopped from the screen that is showing (the Run screen, which has the other Stop, is not).
    @ViewBuilder private var advice: some View {
        if store.runningHere {
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Running the advice the project's config asks for (judge, review stages)…").textStyle(.callout)
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
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        mono(item.command).textSelection(.enabled)
                        Text(item.why).role(.caption)
                    }
                }
                Text("Run these in a terminal. None of them blocks Accept.").role(.caption)
            }
        }
    }

    @ViewBuilder private var denied: some View {
        if !review.denied.isEmpty {
            section("Denied calls") {
                // The grant rows say each call; without them (a Codex turn takes no grants) the counts are all there is.
                if store.sendBackGrants.isEmpty {
                    ForEach(review.denied) { item in
                        Text("\(item.text) ×\(item.count)").textStyle(.monoCallout, .amber)
                    }
                }
                SendBackGrants(store: store)
                Text("Decide each one here before you send guidance to the agent.").role(.caption)
            }
        }
    }

    /// Only what the decision card cannot say. Its buttons (Accept, Send back, Discard, Open diff, worktree, Refresh) live on the card and its menu.
    @ViewBuilder private var actions: some View {
        if review.undecided > 0 {
            let verb = review.undecided == 1 ? "criterion is" : "criteria are"
            Text("\(review.undecided) \(verb) for you to check. Accept does not wait.")
                .role(.caption)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title.uppercased()).textStyle(.captionStrong, .secondary)
            content()
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text).textStyle(.monoCallout).lineLimit(2)
    }
}

/// One file's diff, in the modal over the review.
struct DiffBody: View {
    var store: ProjectStore
    var path: String
    @State private var text = "Reading…"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text(path).textStyle(.heading).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Open in editor") { Task { await store.openDiff(path: path) } }.plainButton(size: .regular)
                    .disabled(store.busy != nil)
            }
            // The modal covers the Review screen, where these are shown otherwise.
            if let error = store.actionError { Text(error).role(.error) }
            if let note = store.actionNote { Text(note).role(.caption) }
            ScrollView {
                Text(text).textStyle(.monoCallout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 400)
        }
        .task { text = await store.patchText(path) }
    }
}

/// What discarding would lose, and the yes.
struct DiscardBody: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let plan = store.pendingDiscard {
                ScrollView {
                    Text(plan.render().joined(separator: "\n")).textStyle(.monoCallout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
                if !plan.fullyShown {
                    Text("Not everything that would be lost could be listed.").role(.warning)
                }
            }
            ModalFooter {
                Button("Cancel") { store.cancelDiscard() }.plainButton(size: .regular)
                Button("Discard", role: .destructive) { Task { await store.confirmDiscard() } }.primaryButton(size: .regular)
            }
        }
    }
}
