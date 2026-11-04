import SwiftUI
import WorkbenchCore

/// What the live run card shows, from the thread's feed and its progress (design parity 8). Nothing here is stored: it is read again
/// from the log on every refresh, and the clock ticks from the turn's start.
struct RunCardModel: Equatable {
    var number: Int
    var progress: WorkbenchCore.Progress
    var limit: TimeInterval?
    var tasks: [FeedItem.PlanTask]
    var tail: [String]
    /// The decision's stop button, when it has one: the card is then the only place a running turn is stopped from.
    var stop: FeedAction?
    /// Open diff, beside Stop: what the turn has changed so far.
    var diff: FeedAction?
    /// The feed's items the card stands for; they are not drawn again.
    var consumed: Set<String>

    static let tailLines = 3

    var done: Int { tasks.filter { $0.state == .done }.count }
    var tasksTitle: String { "TASKS · \(done) OF \(tasks.count)" }

    /// `3:41 of 30:00`, or `3:41` when the turn has no limit.
    static func clock(elapsed: TimeInterval?, limit: TimeInterval?) -> String? {
        guard let elapsed else { return nil }
        let now = mmss(elapsed)
        return limit.map { "\(now) of \(mmss($0))" } ?? now
    }

    static func mmss(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// How far through its time the turn is, 0 to 1 (a turn past its limit shows full), nil without a start or a limit.
    static func fraction(elapsed: TimeInterval?, limit: TimeInterval?) -> Double? {
        guard let elapsed, let limit, limit > 0 else { return nil }
        return min(1, max(0, elapsed / limit))
    }

    /// The card for the turn that is working now; nil when none is (ended, no runner, or nothing started).
    static func make(snapshot: ThreadSnapshot, decision: FeedDecision) -> RunCardModel? {
        guard let index = snapshot.feed.lastIndex(where: { if case .turn(_, .working, _, _) = $0.kind { true } else { false } }),
            case .turn(let number, _, _, _) = snapshot.feed[index].kind
        else { return nil }
        var tasks: [FeedItem.PlanTask] = []
        var tail: [String] = []
        var consumed: Set<String> = [snapshot.feed[index].id]
        let latest = snapshot.feed[index].latest
        for item in snapshot.feed[(index + 1)...] where item.turn == number {
            switch item.kind {
            case .plan(let list):
                tasks = list
                consumed.insert(item.id)
            case .toolGroup(_, let summaries):
                // The group's last calls when it has them (its first few are what the group row shows).
                tail += summaries
                consumed.insert(item.id)
            case .edit(let file, let tool):
                tail.append("\(tool) \(file)")
                consumed.insert(item.id)
            default: break
            }
        }
        let stop = ([decision.primary].compactMap { $0 } + decision.more).first { $0.kind == .stopTurn }
        return RunCardModel(
            number: number, progress: snapshot.state.progress, limit: snapshot.turnTimeoutMin.map { TimeInterval($0 * 60) },
            tasks: tasks, tail: Array((latest.isEmpty ? tail : latest).suffix(tailLines)), stop: stop,
            diff: decision.secondary?.kind == .openDiff ? decision.secondary : nil, consumed: consumed)
    }
}

/// The steps that run after the turn and have not yet: Judge and Verify, each only when it is on for this goal.
struct PendingStep: Equatable, Identifiable {
    var name: String
    var detail: String
    var id: String { name }

    /// The steps to show under the feed: all that are on while the turn works; after it, only the ones that have started and not
    /// ended (a step that has not started may never, when it does not run by itself), each saying it is running.
    static func shown(
        goal: GoalModel?, criteria: Int, working: Bool, judgeRunning: Bool, verifyRunning: Bool
    ) -> [PendingStep] {
        if working { return pending(goal: goal, criteria: criteria, have: []) }
        let running: Set<String> = Set([judgeRunning ? "Judge" : nil, verifyRunning ? "Verify" : nil].compactMap { $0 })
        return pending(goal: goal, criteria: criteria, have: []).filter { running.contains($0.name) }
            .map { PendingStep(name: $0.name, detail: "running now") }
    }

    static func pending(goal: GoalModel?, criteria: Int, have: Set<String>) -> [PendingStep] {
        guard let goal else { return [] }
        func on(_ name: String) -> Bool {
            guard let step = goal.steps.first(where: { $0.name == name }) else { return false }
            return !step.skipped && step.unavailable == nil
        }
        var out: [PendingStep] = []
        if on("judge"), !have.contains("judge") {
            let noun = criteria == 1 ? "criterion" : "criteria"
            out.append(PendingStep(name: "Judge", detail: "starts when the run ends · \(criteria) \(noun)"))
        }
        if on("verifier"), !have.contains("verifier") {
            out.append(PendingStep(name: "Verify", detail: "drives the app, posts screenshots here"))
        }
        return out
    }
}

struct RunCardView: View {
    var model: RunCardModel
    var perform: (FeedAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = model.progress.elapsed(now: context.date)
                header(elapsed: elapsed)
                if let fraction = RunCardModel.fraction(elapsed: elapsed, limit: model.limit) {
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.blue)
                        .accessibilityLabel("Time used").accessibilityValue("\(Int(fraction * 100)) percent")
                }
            }
            if !model.tasks.isEmpty || !model.tail.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.tasks.isEmpty { tasks }
                    if !model.tail.isEmpty { tail }
                }
                .padding(Spacing.inset)
            }
            if let stop = model.stop { footer(stop, diff: model.diff) }
        }
        .card(clips: true)
        .accessibilityElement(children: .contain)
    }

    private func header(elapsed: TimeInterval?) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).frame(width: 16)
            Text("Claude is working").textStyle(.calloutStrong)
            Spacer(minLength: 8)
            if let clock = RunCardModel.clock(elapsed: elapsed, limit: model.limit) {
                Text(clock).role(.monoDetail)
            }
        }
        .padding(.horizontal, Spacing.inset).padding(.vertical, 10)
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.tasksTitle).textStyle(.captionStrong, .secondary)
            ForEach(Array(model.tasks.enumerated()), id: \.offset) { _, task in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    mark(task.state)
                    Text(task.text).textStyle(.callout).fontWeight(task.state == .working ? .semibold : .regular)
                        .foregroundStyle(task.state == .pending ? .secondary : .primary).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(task.state == .done ? "done" : task.state == .working ? "working" : "to do")
            }
        }
    }

    @ViewBuilder private func mark(_ state: FeedItem.PlanTask.State) -> some View {
        switch state {
        case .done: Image(systemName: "checkmark").foregroundStyle(Theme.green).frame(width: 14)
        case .working: ProgressView().controlSize(.mini).frame(width: 14)
        case .pending: Image(systemName: "circle").foregroundStyle(Theme.fg3).frame(width: 14)
        }
    }

    private var tail: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.tail.enumerated()), id: \.offset) { _, line in
                Text(line).role(.mono).lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .callout(.well)
    }

    private func footer(_ stop: FeedAction, diff: FeedAction?) -> some View {
        HStack {
            Spacer()
            if let diff {
                ActionButton(action: diff, size: .compact, symbol: "doc.text.magnifyingglass", perform: perform)
            }
            ActionButton(action: stop, size: .compact, symbol: "stop.fill", perform: perform)
        }
        .padding(.horizontal, Spacing.inset).padding(.bottom, 12)
    }
}

/// A step that comes after the run and has not started: a grey ring, its name, and what it will do.
struct PendingStepRow: View {
    var step: PendingStep

    var body: some View {
        IconRow(symbol: "circle", tint: Theme.fg3) {
            Text(step.name).textStyle(.calloutStrong)
            Spacer(minLength: 8)
            Text(step.detail).role(.detail).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the latest finished turn adds to its row: how many tasks the agent listed, the diff's files and lines, and what View diff does.
struct FinishContext {
    var tasks: Int?
    var totals: String?
    var viewDiff: () -> Void
}

/// The agent's task list in a turn that is no longer working: the same list, as one row.
struct PlanRow: View {
    var tasks: [FeedItem.PlanTask]

    var body: some View {
        let done = tasks.filter { $0.state == .done }.count
        FeedLine(
            symbol: done == tasks.count ? "checklist.checked" : "checklist", tint: done == tasks.count ? Theme.green : Theme.grey,
            title: "Tasks · \(done) of \(tasks.count)", detail: tasks.map(\.text).joined(separator: " · "), inline: false)
    }
}

/// One screenshot the verifier left: where it is and the words under it.
struct ProofShot: Equatable, Identifiable {
    var url: URL
    var caption: String
    var id: URL { url }

    static let shown = 3
    /// Longest side a thumbnail is decoded at, so a large PNG costs a small image.
    static let thumbnailPixels = 480

    /// `list-states.png` is "list states". Only PNGs the verifier recorded, the first few, in the order recorded.
    static func shots(from recorded: [ProofFile], threadDirectory: URL) -> [ProofShot] {
        // Only a file that is still what the log recorded: a regular file of the recorded size, not a link.
        let files = recorded.filter { $0.isAvailable(in: threadDirectory) }.map { (name: $0.name, path: $0.path) }
        return files.filter { $0.name.lowercased().hasSuffix(".png") }.prefix(shown).map {
            let stem = ($0.name as NSString).deletingPathExtension
                .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return ProofShot(url: threadDirectory.appendingPathComponent($0.path), caption: stem)
        }
    }
}

struct ProofThumbnail: View {
    var shot: ProofShot
    @State private var image: CGImage?
    @State private var missing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    Rectangle().fill(Theme.canvas)
                        .overlay { if missing { Image(systemName: "photo").foregroundStyle(Theme.fg3) } }
                        .aspectRatio(16 / 10, contentMode: .fit)
                }
            }
            .thumbnail(outlined: true)
            Text(shot.caption).role(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine).accessibilityLabel("Screenshot: \(shot.caption)")
        .task(id: shot.url) {
            let url = shot.url
            let loaded = await Task.detached(priority: .utility) { Self.decode(url) }.value
            (image, missing) = (loaded, loaded == nil)
        }
    }

    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ProofShot.thumbnailPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
