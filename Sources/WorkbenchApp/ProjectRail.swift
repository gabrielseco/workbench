import SwiftUI
import WorkbenchCore

/// The column of projects (P26): a tile for each, the open one marked, a tile for the inbox of every project (arriving with the inbox view),
/// and `+` to add one. A tile's menu is where a project's own actions are: its agents, Doctor, the folder, and taking it off the rail.
struct ProjectRail: View {
    var store: ProjectStore
    static let width: CGFloat = 72

    var body: some View {
        ScrollView {
            VStack(spacing: Space.m) {
                allProjects
                Divider().frame(width: Space.xxxl - Space.xs)
                ForEach(store.railTiles()) { tile in
                    ProjectTile(
                        project: tile, selected: tile.path == store.project?.root.path, badge: store.railBadge(for: tile.path)
                    ) {
                        Task { await store.pickRecent(tile.path) }
                    }
                    .contextMenu { menu(for: tile) }
                }
                addProject
            }
            .padding(.vertical, Space.l).frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(width: Self.width)
    }

    /// The tile for the inbox of every project: the inbox view that fills it is a later slice, so it only says so.
    private var allProjects: some View {
        Button {} label: {
            Label("All projects", systemImage: "tray.full").labelStyle(.iconOnly).textStyle(.heading, .secondary)
                .frame(width: ProjectTile.side, height: ProjectTile.side)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain).disabled(true)
        .overlay(alignment: .topTrailing) {
            if let kind = CountBadge.Kind(store.allProjectsBadge()) { CountBadge(kind: kind).offset(x: Space.s, y: -Space.s) }
        }
        .accessibilityLabel(store.allProjectsBadge().label(for: "All projects inbox"))
        .help("The inbox of every project: it arrives with the inbox view")
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
