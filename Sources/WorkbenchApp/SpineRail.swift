import SwiftUI
import WorkbenchCore

/// The thread's seven steps, drawn from `ThreadSpine` and nothing else: the view holds no state machine.
struct SpineRail: View {
    var snapshot: ThreadSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("THREAD").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
            Text(snapshot.title ?? snapshot.id).font(.headline).lineLimit(2).padding(.bottom, 14)
            ForEach(Array(snapshot.spine.entries.enumerated()), id: \.offset) { index, entry in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Image(systemName: entry.mark.symbol).foregroundStyle(Theme.color(for: entry.mark))
                        if index < snapshot.spine.entries.count - 1 {
                            Rectangle().fill(Theme.grey.opacity(0.4)).frame(width: 1).frame(minHeight: 12)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.step.title)
                            .font(.body.weight(entry.mark == .pending ? .regular : .semibold))
                            .foregroundStyle(entry.mark == .pending ? Color.secondary : Color.primary)
                        if !entry.sublabel.isEmpty {
                            Text(entry.sublabel).font(.caption).foregroundStyle(Theme.color(for: entry.mark))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.step.title), \(entry.mark.rawValue), \(entry.sublabel)")
            }
        }
    }
}
