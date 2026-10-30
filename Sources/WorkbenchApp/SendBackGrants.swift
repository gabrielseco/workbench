import SwiftUI
import WorkbenchCore

/// One denied command a person can decide about in the Send back card: a whole call, or one part of a compound (a compound cannot
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
            VStack(alignment: .leading, spacing: 8) {
                Text("DENIED CALLS").font(.caption2.weight(.semibold)).tracking(0.9).foregroundStyle(.secondary)
                // A scroll view takes all the height it is allowed, so a short list is not put in one.
                let rows = VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.sendBackGrants) { GrantRowView(store: store, row: $0) }
                }
                if store.sendBackGrants.count > 3 {
                    ScrollView { rows }.frame(maxHeight: 190)
                } else {
                    rows
                }
                Text("A decision is saved when you make it and stays if you cancel.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GrantRowView: View {
    var store: ProjectStore
    var row: GrantRow
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.command).font(.system(.callout, design: .monospaced)).lineLimit(2).textSelection(.enabled)
            HStack(spacing: 8) {
                if row.level != .safe {
                    Text(row.level == .unsafe ? "unsafe" : "caution").font(.caption)
                        .foregroundStyle(row.level == .unsafe ? Theme.red : Theme.amber)
                }
                if let reason = row.reasons.first { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)
                if let decided = row.decided { Text(decided).font(.caption).foregroundStyle(Theme.green) }
                choices
            }
            if confirming {
                HStack {
                    Text("This is rated unsafe. Allow it for the next turn only?").font(.caption).foregroundStyle(Theme.red)
                    Spacer()
                    Button("Cancel") { confirming = false }
                    Button("Allow once") {
                        confirming = false
                        Task { await store.decide(row, .once, dangerous: true) }
                    }
                }
                .controlSize(.small)
            }
            if let refusal = row.refusal { Text(refusal).font(.caption).foregroundStyle(Theme.red) }
        }
    }

    @ViewBuilder private var choices: some View {
        HStack(spacing: 6) {
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
