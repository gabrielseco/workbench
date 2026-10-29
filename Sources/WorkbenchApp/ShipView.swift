import SwiftUI
import WorkbenchCore

/// Ship's confirmation: what will be pushed and the pull request's title and text, shown before anything leaves the machine.
struct ShipSheet: View {
    var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ship this work").font(.headline)
            if let preview = store.pendingShip {
                Text(preview.pushLines.joined(separator: "\n")).font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let title = preview.title, let body = preview.body {
                    Text(title).font(.body.weight(.semibold))
                    ScrollView {
                        Text(body.trimmingCharacters(in: .newlines)).font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                } else {
                    Text("Pushes to the open pull request on \(preview.plan.remoteBranch); its title and text stay as they are.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let note = preview.note { Text(note).font(.callout).foregroundStyle(Theme.amber) }
                Text("Workbench never merges for you.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.cancelShip() }
                Button("Push and open PR") { Task { await store.confirmShip() } }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 600)
    }
}
