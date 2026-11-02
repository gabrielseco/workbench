import SwiftUI
import WorkbenchCore

/// One row of the feed. Colour keeps its five meanings and every row also says it in words or a symbol: blue working, green done,
/// amber needs you, red broken, grey idle.
struct FeedRow: View {
    var item: FeedItem

    var body: some View {
        switch item.kind {
        case .userNote(let text): UserNoteRow(text: text)
        case .goalCard(let title, let approval, let criteria, let hash):
            GoalCardRow(title: title, approval: approval, criteria: criteria, hash: hash)
        case .turn(let number, let phase, let durationMs, let cost):
            TurnRow(number: number, phase: phase, durationMs: durationMs, cost: cost)
        case .agentText(let text):
            Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .toolGroup(let count, let summaries): ToolGroupRow(count: count, summaries: summaries)
        case .edit(let file, let tool):
            FeedLine(symbol: "pencil", tint: Theme.grey, title: tool, detail: file, mono: true, inline: true)
        case .denied(let tool, let input):
            FeedLine(
                symbol: "hand.raised.fill", tint: Theme.amber, title: "Refused \(tool)", detail: input, mono: true, inline: true)
        case .check(let result, let command, let durationMs): CheckRow(result: result, command: command, durationMs: durationMs)
        case .judge(let ok, let criteria, let unmet, let concerns):
            JudgeRow(ok: ok, criteria: criteria, unmet: unmet, concerns: concerns)
        case .verify(let ok, let reason, let proofs): VerifyRow(ok: ok, reason: reason, proofs: proofs)
        case .decision(let text):
            FeedLine(
                symbol: text == "accepted" ? "checkmark.circle.fill" : "minus.circle.fill",
                tint: text == "accepted" ? Theme.green : Theme.grey, title: text.capitalized, detail: nil)
        case .pullRequest(let number, let url):
            FeedLine(
                symbol: "arrow.up.right.circle.fill", tint: Theme.green,
                title: number.map { "Shipped as PR #\($0)" } ?? "Shipped", detail: url, inline: true)
        case .prReview(let round, let verdict, let ok): PRReviewRow(round: round, verdict: verdict, ok: ok)
        case .next(let step, let why): NextCard(step: step, why: why)
        case .notice(let notice): NoticeRow(notice: notice)
        }
    }
}

/// A symbol, a line of words and, beneath, the detail it is about: the shape of most rows.
struct FeedLine: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String?
    var mono = false
    /// The detail follows the title on one line (a file, a command) instead of sitting under it (a sentence of explanation).
    var inline = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            if inline {
                Text(title).font(.callout).foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
                if let detail, !detail.isEmpty { detailText(detail).lineLimit(1) }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).foregroundStyle(.primary)
                    if let detail, !detail.isEmpty { detailText(detail).lineLimit(2) }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail).font(mono ? .system(.callout, design: .monospaced) : .callout).foregroundStyle(.secondary)
            .truncationMode(.middle).textSelection(.enabled)
    }
}

struct UserNoteRow: View {
    var text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text("You · sent back").font(.caption).foregroundStyle(.secondary)
                Text(text).font(.body).textSelection(.enabled)
            }
            .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct GoalCardRow: View {
    var title: String?
    var approval: ApprovalState?
    var criteria: Int
    var hash: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GOAL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(title ?? "Goal").font(.headline).lineLimit(2)
            HStack(spacing: 10) {
                Label(approvalText, systemImage: approvalSymbol).foregroundStyle(approvalTint)
                Text("\(criteria) \(criteria == 1 ? "criterion" : "criteria")").foregroundStyle(.secondary)
                if let hash, !hash.isEmpty {
                    Text(String(hash.prefix(7))).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.grey.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var approvalText: String {
        switch approval {
        case .approved?: "Approved"
        case .draft?: "Draft · not approved"
        case .stale?: "Changed since approval"
        case nil: "unknown"
        }
    }

    private var approvalSymbol: String {
        switch approval {
        case .approved?: "checkmark.circle.fill"
        case .stale?: "exclamationmark.circle.fill"
        default: "circle"
        }
    }

    private var approvalTint: Color {
        switch approval {
        case .approved?: Theme.green
        case .stale?: Theme.amber
        default: Theme.grey
        }
    }
}

struct TurnRow: View {
    var number: Int
    var phase: FeedItem.Phase
    var durationMs: Int?
    var cost: Double?

    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .working: ProgressView().controlSize(.small).frame(width: 16)
            default: Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            }
            Text(title).font(.callout.weight(.semibold))
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch phase {
        case .working: "Turn \(number) · working"
        case .orphaned: "Turn \(number) · the runner is gone"
        case .unrecorded: "Turn \(number) · how it ended is not recorded"
        case .ended(let result):
            switch result {
            case "succeeded": "Turn \(number) ended"
            case "timed_out": "Turn \(number) timed out"
            case "budget_exceeded": "Turn \(number) went over budget"
            default: "Turn \(number) \(result.replacingOccurrences(of: "_", with: " "))"
            }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let durationMs { parts.append(Self.duration(durationMs)) }
        if let cost { parts.append(String(format: "$%.2f", cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch phase {
        case .ended("succeeded"): "checkmark.circle.fill"
        case .ended("stopped"): "minus.circle.fill"
        case .orphaned: "exclamationmark.circle.fill"
        case .unrecorded: "questionmark.circle"
        default: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch phase {
        case .working: Theme.blue
        case .ended("succeeded"): Theme.green
        case .ended("stopped"), .unrecorded: Theme.grey
        case .orphaned: Theme.amber
        default: Theme.red
        }
    }

    static func duration(_ ms: Int) -> String {
        let seconds = ms / 1000
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

struct ToolGroupRow: View {
    var count: Int
    var summaries: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "wrench.and.screwdriver").foregroundStyle(Theme.grey).frame(width: 16)
            Text("\(count) tool \(count == 1 ? "call" : "calls")").font(.callout)
            Text(summaries.joined(separator: " · ") + (count > summaries.count ? " …" : ""))
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CheckRow: View {
    var result: String
    var command: String?
    var durationMs: Int?

    var body: some View {
        let passed = result == "passed"
        FeedLine(
            symbol: passed ? "checkmark.circle.fill" : "xmark.circle.fill", tint: passed ? Theme.green : Theme.red,
            title: "Check \(result.replacingOccurrences(of: "_", with: " "))"
                + (durationMs.map { " · " + TurnRow.duration($0) } ?? ""),
            detail: command, mono: true, inline: true)
    }
}

struct JudgeRow: View {
    var ok: Bool
    var criteria: Int
    var unmet: Int
    var concerns: Int

    var body: some View {
        if !ok {
            FeedLine(symbol: "questionmark.circle", tint: Theme.grey, title: "The judge did not answer", detail: nil)
        } else if unmet == 0 {
            FeedLine(
                symbol: "checkmark.circle.fill", tint: Theme.green,
                title: "Judge agrees · \(criteria) of \(criteria) criteria met", detail: concernText)
        } else {
            FeedLine(
                symbol: "exclamationmark.circle.fill", tint: Theme.amber,
                title: "Judge: \(criteria - unmet) of \(criteria) criteria met", detail: concernText)
        }
    }

    private var concernText: String? { concerns > 0 ? "\(concerns) \(concerns == 1 ? "concern" : "concerns")" : nil }
}

struct VerifyRow: View {
    var ok: Bool
    var reason: String?
    var proofs: [String]

    var body: some View {
        FeedLine(
            symbol: ok ? "checkmark.circle.fill" : "xmark.circle.fill", tint: ok ? Theme.green : Theme.red,
            title: ok ? "Verify passed" : "Verify failed" + (reason.map { ": \($0)" } ?? ""),
            detail: proofs.isEmpty ? nil : proofs.joined(separator: ", "))
    }
}

struct PRReviewRow: View {
    var round: Int?
    var verdict: String?
    var ok: Bool

    var body: some View {
        let clean = ok && verdict == "clean"
        FeedLine(
            symbol: clean ? "checkmark.circle.fill" : (ok ? "exclamationmark.circle.fill" : "xmark.circle.fill"),
            tint: clean ? Theme.green : (ok ? Theme.amber : Theme.red),
            title: "PR review" + (round.map { " round \($0)" } ?? "") + (verdict.map { " · \($0)" } ?? ""), detail: nil)
    }
}

/// The one next step and why, from the spine and attention. It is a statement, not a button: the buttons stay on the step screens.
struct NextCard: View {
    var step: SpineStep?
    var why: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEXT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(step?.title ?? "Nothing left to do").font(.headline)
            Text(why).font(.callout).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.grey.opacity(0.4)))
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

struct NoticeRow: View {
    var notice: FeedItem.Notice

    var body: some View {
        switch notice {
        case .activityNotStored(let count):
            FeedLine(symbol: "ellipsis.circle", tint: Theme.grey, title: "\(count) activity items were not stored", detail: nil)
        case .activityFolded(let count, let refusals):
            FeedLine(
                symbol: "ellipsis.circle", tint: Theme.grey, title: "\(count) more items in this turn are folded",
                detail: (refusals > 0 ? "\(refusals) of them refused calls. " : "") + "Open the event log to see them.")
        case .logDamaged(let problems, let first):
            FeedLine(
                symbol: "xmark.octagon.fill", tint: Theme.red,
                title: "The log has \(problems) damaged \(problems == 1 ? "line" : "lines"); this shows what could be read.",
                detail: first + ". Open the event log to see it; Workbench never rewrites it.")
        case .logTailCut:
            FeedLine(
                symbol: "scissors", tint: Theme.grey, title: "The last line of the log was cut short, as a crash leaves it",
                detail: nil)
        case .goalChangedSinceApproval:
            FeedLine(
                symbol: "exclamationmark.circle.fill", tint: Theme.amber, title: "The goal changed since it was approved",
                detail: "Approve it again before it runs.")
        case .earlierNotShown(let count):
            FeedLine(
                symbol: "ellipsis.circle", tint: Theme.grey, title: "\(count) earlier items are not shown",
                detail: "Open the event log to see them.")
        }
    }
}
