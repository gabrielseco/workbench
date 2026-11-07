import AppKit
import SwiftUI

/// The card under the project pill: the recent projects with the open one marked, a search field, ↑↓ and ↵, and "Choose folder…" at
/// the bottom. It stands on `.modal` (Esc, the close button and a click outside close it, since nothing typed in it is worth keeping).
struct ProjectPickerCard: View {
    var store: ProjectStore
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var focused: Bool

    private var rows: [RecentProject] { ProjectStore.filter(store.recentProjects(), query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            search
            list.padding(.top, Space.m)
            if let error = store.actionError {
                Text(error).role(.error)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, Space.s)
            }
            Divider().padding(.top, Space.m)
            footer.padding(.top, Space.m)
        }
        .onAppear {
            store.actionError = nil
            selected = defaultSelection
        }
        // As in the New goal card: focus set before the overlay is in the window is lost, one tick later it takes.
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
        }
        .onChange(of: query) { selected = defaultSelection }
    }

    /// The first project that can be opened and is not the open one, so ↵ goes back to the previous project.
    private var defaultSelection: String? {
        let open = rows.filter { $0.unavailable == nil }
        return (open.first { !$0.isCurrent } ?? open.first)?.path
    }

    private var search: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find a project", text: $query)
                .textFieldStyle(.plain).focused($focused)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return) {
                    guard let selected else { return .ignored }
                    pick(selected)
                    return .handled
                }
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .background(Theme.grey.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.box))
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let open = rows.filter { $0.unavailable == nil }.map(\.path)
        guard !open.isEmpty else { return .ignored }
        let now = selected.flatMap { open.firstIndex(of: $0) } ?? (step > 0 ? -1 : open.count)
        selected = open[min(max(now + step, 0), open.count - 1)]
        return .handled
    }

    private func pick(_ path: String) { Task { await store.pickRecent(path) } }

    @ViewBuilder private var list: some View {
        if rows.isEmpty {
            Text(store.recentPaths.isEmpty ? "No recent projects yet." : "No project matches \"\(query)\".")
                .role(.detail).padding(.vertical, Space.m).padding(.horizontal, Space.xs)
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: Space.xxs) {
                        ForEach(rows) { entry in
                            ProjectRow(entry: entry, highlighted: entry.path == selected, pick: pick) { store.forget(entry.path) }
                                .id(entry.path)
                        }
                    }
                }
                // More rows than fit: keep the one ↑↓ and ↵ act on in view.
                .onChange(of: selected) {
                    guard let selected else { return }
                    scroller.scrollTo(selected)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await store.chooseFolder() }
            } label: {
                Label("Choose folder…", systemImage: "folder.badge.plus")
            }
            .accessibilityLabel("Choose folder…")
            Spacer()
            Text("↑↓ move  ·  ↵ open  ·  esc close").textStyle(.caption, .tertiary)
        }
    }

    /// The file panel the app asks for a folder with; nil when it is cancelled.
    @MainActor static func folderPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder of a git repository"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// One project: its name and where it is, marked when it is the open one or has a run going, and why when it cannot be opened.
private struct ProjectRow: View {
    var entry: RecentProject
    var highlighted: Bool
    var pick: (String) -> Void
    var remove: () -> Void
    @State private var hovered = false

    private var available: Bool { entry.unavailable == nil }

    var body: some View {
        HStack(spacing: Space.m) {
            Button {
                pick(entry.path)
            } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: entry.isCurrent ? "folder.fill" : "folder")
                        .foregroundStyle(entry.isCurrent ? Theme.blue : .secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(entry.name).textStyle(entry.isCurrent ? .bodyStrong : .body)
                            .foregroundStyle(available ? .primary : .secondary)
                        Text(entry.unavailable ?? (entry.path as NSString).abbreviatingWithTildeInPath)
                            .textStyle(.mono)
                            .foregroundStyle(available ? Color.secondary : Theme.red)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if entry.isRunning { Text("Running").pill(Theme.blue) }
                    if entry.isCurrent { Text("Current").pill(Theme.blue) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!available)
            .accessibilityLabel(entry.name + (entry.isCurrent ? ", current project" : "") + (entry.isRunning ? ", running" : ""))
            .help(entry.unavailable ?? entry.path)
            if !available {
                Button("Remove", action: remove).controlSize(.small)
                    .accessibilityLabel("Remove \(entry.name) from the list")
            }
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.box).fill(
                highlighted ? Theme.blue.opacity(0.14) : (hovered && available ? Theme.grey.opacity(0.12) : .clear)))
        .onHover { hovered = $0 }
    }
}
