import SwiftUI
import WorkbenchCore

/// The column of projects (P26): a tile for each, the open one marked, a tile for the inbox of every project,
/// and `+` to add one. A tile's menu is where a project's own actions are: its agents, Doctor, the folder, and taking it off the rail.
struct ProjectRail: View {
    var store: ProjectStore
    static let width: CGFloat = 72
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: Space.m) {
                allProjects
                Divider().frame(width: Space.xxxl - Space.xs)
                ForEach(store.railTiles()) { tile in
                    ProjectTile(
                        project: tile, selected: tile.path == store.project?.root.path && !store.allProjects,
                        badge: store.railBadge(for: tile.path)
                    ) {
                        Task { await store.pickRecent(tile.path) }
                    }
                    .contextMenu { menu(for: tile) }
                }
                addProject
            }
            .padding(.vertical, Space.l).frame(maxWidth: .infinity)
            // One focus stop for the rail, as in the automations list: Tab lands here, the arrows walk the tiles (the inbox of every
            // project, then each project), and the open one is the one marked.
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onChange(of: focused) { store.railFocused = focused }
            .onMoveCommand { direction in
                guard direction == .up || direction == .down else { return }
                Task { await store.moveRailSelection(by: direction == .up ? -1 : 1) }
            }
        }
        .scrollIndicators(.hidden)
        .frame(width: Self.width)
    }

    /// The tile for the inbox of every project: chosen, the rail lists theirs together; a project's tile goes back to its own.
    private var allProjects: some View {
        let everything = RailProject(path: "", name: "All projects inbox", initials: "", unavailable: nil)
        return ProjectTile(
            project: everything, selected: store.allProjects, badge: store.allProjectsBadge(), symbol: "tray.full",
            tooltip: "The inbox of every project on the rail"
        ) {
            Task { await store.showAllProjects() }
        }
    }

    private var addProject: some View {
        Button {
            store.pickingProject.toggle()
        } label: {
            Label("Add project", systemImage: "plus").labelStyle(.iconOnly).textStyle(.heading, .secondary)
                .frame(width: ProjectTile.side, height: ProjectTile.side)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Theme.line, style: StrokeStyle(dash: [Space.xs])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add project").help("Add a project: the recent ones, or a folder")
    }

    @ViewBuilder private func menu(for tile: RailProject) -> some View {
        Button("Agents…") { store.showAgents(for: tile.path) }.disabled(tile.unavailable != nil)
        Button("Doctor") { Task { await store.runDoctor(at: tile.path) } }.disabled(tile.unavailable != nil)
        Button("Reveal in Finder") { store.revealInFinder(tile.path) }.disabled(tile.unavailable != nil)
        Divider()
        Button("Move up") { store.moveOnRail(tile.path, by: -1) }
        Button("Move down") { store.moveOnRail(tile.path, by: 1) }
        Divider()
        Button("Remove from rail", role: .destructive) { Task { await store.removeFromRail(tile.path) } }
    }
}
