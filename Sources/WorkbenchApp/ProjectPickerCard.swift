import AppKit
import SwiftUI

/// The project card under the pill, over a light veil: a click on the veil closes it.
struct ProjectPickerLayer: View {
    var store: ProjectStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            if store.pickingProject {
                Color.black.opacity(0.12).contentShape(Rectangle())
                    .onTapGesture { store.pickingProject = false }.transition(.opacity)
                ProjectPickerCard(store: store).padding(.top, 44).padding(.leading, 10)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.pickingProject)
        .accessibilityAddTraits(store.pickingProject ? .isModal : [])
    }
}

/// The card under the project pill: the recent projects with the open one marked, a search field, ↑↓ and ↵, and "Choose folder…" at
/// the bottom. It has the New goal card's look; a click outside closes it, since nothing typed in it is worth keeping.
struct ProjectPickerCard: View {
    var store: ProjectStore
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var focused: Bool

    private var rows: [RecentProject] { ProjectStore.filter(store.recentProjects(), query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            search.padding(.top, 12)
            list.padding(.top, 10)
            if let error = store.actionError {
                Text(error).font(.callout).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            Divider().padding(.top, 10)
            footer.padding(.top, 10)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
        .frame(width: 420)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .onExitCommand(perform: close)
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

    private func close() { store.pickingProject = false }

    /// The first project that can be opened and is not the open one, so ↵ goes back to the previous project.
    private var defaultSelection: String? {
        let open = rows.filter { $0.unavailable == nil }
        return (open.first { !$0.isCurrent } ?? open.first)?.path
    }

    private var header: some View {
        HStack {
            Text("Projects".uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.9).foregroundStyle(.secondary)
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Close the projects panel")
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.grey.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 10).padding(.horizontal, 4)
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 2) {
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
            Text("↑↓ move  ·  ↵ open  ·  esc close").font(.caption).foregroundStyle(.tertiary)
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
        HStack(spacing: 10) {
            Button {
                pick(entry.path)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: entry.isCurrent ? "folder.fill" : "folder")
                        .foregroundStyle(entry.isCurrent ? Theme.blue : .secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).font(.body.weight(entry.isCurrent ? .semibold : .regular))
                            .foregroundStyle(available ? .primary : .secondary)
                        Text(entry.unavailable ?? (entry.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(available ? Color.secondary : Theme.red)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if entry.isRunning { Badge(text: "Running", tint: Theme.blue) }
                    if entry.isCurrent { Badge(text: "Current", tint: Theme.blue) }
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
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(
                highlighted ? Theme.blue.opacity(0.14) : (hovered && available ? Theme.grey.opacity(0.12) : .clear)))
        .onHover { hovered = $0 }
    }
}

private struct Badge: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(tint).background(tint.opacity(0.12), in: Capsule())
    }
}
