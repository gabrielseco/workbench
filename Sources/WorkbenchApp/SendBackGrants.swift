import SwiftUI
import WorkbenchCore

/// One denied command a person can decide about in the Review card: a whole call, or one part of a compound (a compound cannot
/// be granted as a whole). The numbers are core's (`3`, `3.2`), the ones `workbench grant` shows.
struct GrantRow: Identifiable, Equatable {
    var number: String
    var command: String
    var level: DeniedCommandAssessment.Level
    var reasons: [String]
    var status: GrantStatus
    /// Core's refusal of the last choice made on this row, in its own words.
    var refusal: String?

    var id: String { number }
    /// An unsafe part can only be allowed once, and only after a confirm of its own.
    var onlyOnce: Bool { level == .unsafe }

    static func rows(_ candidates: [GrantCandidate]) -> [GrantRow] {
        candidates.flatMap { candidate in
            candidate.parts.map {
                GrantRow(number: $0.number, command: $0.command, level: $0.level, reasons: $0.reasons, status: $0.status)
            }
        }
    }

    /// What was decided, as the row says it.
    var decided: String? {
        switch status {
        case .open: nil
        case .granted(.once): "Allowed for the next turn"
        case .granted(.thread): "Allowed for this thread"
        case .granted(.never): "Never"
        case .refused: "Never"
        }
    }
}

/// The denied calls in the Send back card, each with the three choices core has: the next turn, this thread, never. An unsafe part
/// offers only the next turn, behind a confirm of its own.
struct SendBackGrants: View {
    var store: ProjectStore

    var body: some View {
        if !store.sendBackGrants.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionLabel("DENIED CALLS")
                // A scroll view takes all the height it is allowed, so a short list is not put in one.
                let rows = VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(store.sendBackGrants) { GrantRowView(store: store, row: $0) }
                }
                if store.sendBackGrants.count > 3 {
                    ScrollView { rows }.frame(maxHeight: 190)
                } else {
                    rows
                }
                Text("A decision is saved when you make it.").role(.caption)
            }
        }
    }
}

private struct GrantRowView: View {
    var store: ProjectStore
    var row: GrantRow
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(row.command).textStyle(.monoCallout).lineLimit(2).textSelection(.enabled)
            HStack(spacing: Space.s) {
                if row.level != .safe {
                    Text(row.level == .unsafe ? "unsafe" : "caution").textStyle(.caption)
                        .foregroundStyle(row.level == .unsafe ? Theme.red : Theme.amber)
                }
                if let reason = row.reasons.first { Text(reason).role(.caption).lineLimit(1) }
                Spacer(minLength: Space.s)
                if let decided = row.decided { Text(decided).textStyle(.caption, .green) }
                choices
            }
            if confirming {
                HStack {
                    Text("This is rated unsafe. Allow it for the next turn only?").textStyle(.caption, .red)
                    Spacer()
                    Button("Cancel") { confirming = false }.plainButton()
                    Button("Allow once") {
                        confirming = false
                        Task { await store.decide(row, .once, dangerous: true) }
                    }
                }
                .controlSize(.small)
            }
            if let refusal = row.refusal { Text(refusal).textStyle(.caption, .red) }
        }
    }

    @ViewBuilder private var choices: some View {
        HStack(spacing: Space.s) {
            if row.onlyOnce {
                Button("Once…") { confirming = true }
            } else {
                Button("Once") { Task { await store.decide(row, .once) } }
                Button("Thread") { Task { await store.decide(row, .thread) } }
            }
            Button("Never") { Task { await store.decide(row, .never) } }
        }
        .controlSize(.small)
        .disabled(store.grantsInFlight > 0)
    }
}
