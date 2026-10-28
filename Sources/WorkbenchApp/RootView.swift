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

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Picker.chooseProject(store)
            } label: {
                HStack(spacing: 4) {
                    Text(store.project?.root.lastPathComponent ?? "Choose project")
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
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
            ThreadPane(snapshot: snapshot)
        } else if let message = store.screen.message {
            EmptyState(title: message.title, next: message.next, store: store)
        }
    }
}

struct ThreadPane: View {
    var snapshot: ThreadSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.title ?? snapshot.id).font(.title.weight(.bold))
            Text(".workbench/threads/\(snapshot.id)/goal.md")
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            if case .needsYou(let reason) = snapshot.attention {
                Label(reason.text, systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.amber).padding(.top, 8)
            }
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
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
            Button("Choose project…") { Picker.chooseProject(store) }.padding(.top, 6)
        }
        .padding(40)
    }
}

struct FooterBar: View {
    var store: ProjectStore

    var body: some View {
        HStack {
            if case .thread(let snapshot) = store.screen {
                Button {
                    NSWorkspace.shared.open(snapshot.logURL)
                } label: {
                    Text("Event log \(snapshot.lastSeq)").foregroundStyle(Theme.blue)
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
