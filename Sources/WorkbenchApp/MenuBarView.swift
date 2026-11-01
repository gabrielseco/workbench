import AppKit
import SwiftUI
import WorkbenchCore

/// The status item: the icon always, and the count only while something needs you, amber or (when something broke) red. The system
/// draws a menu bar item as a template, so the colour may be lost there: the count and the VoiceOver label carry the meaning.
struct MenuBarLabel: View {
    var store: ProjectStore

    var body: some View {
        let model = MenuBarLabelModel.make(items: store.attention.items)
        HStack(spacing: 3) {
            Image(systemName: "wrench.and.screwdriver")
            if model.total > 0 { Text("\(model.total)").monospacedDigit() }
        }
        .foregroundStyle(model.tone.map { Theme.color(for: $0) } ?? Color.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibility)
    }
}

/// What the status item opens (mockup 5): the same store as the window, so it cannot disagree with it. It decides nothing: every
/// button brings the window forward at the place where the decision is made.
struct MenuBarPopover: View {
    var store: ProjectStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let model = MenuBarPopoverModel.make(
            project: store.project, screen: store.screen, items: store.attention.items, review: store.review,
            denied: store.attention.notificationsDenied, deniedShown: store.attention.deniedWasShown)
        VStack(alignment: .leading, spacing: 10) {
            header(model)
            content(model)
            if let note = model.deniedNote {
                Label(note, systemImage: "bell.slash").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14).frame(width: 320)
        .onDisappear { if model.deniedNote != nil { store.attention.sayDeniedOnce() } }
    }

    private func header(_ model: MenuBarPopoverModel) -> some View {
        HStack {
            Text((model.project ?? "Workbench").uppercased()).font(.caption.weight(.semibold)).tracking(0.9)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            let (word, tone) = pill(model.status)
            Text(word).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 2)
                .foregroundStyle(Theme.color(for: tone)).background(Theme.color(for: tone).opacity(0.14), in: Capsule())
        }
    }

    private func pill(_ status: MenuBarPopoverModel.Status) -> (String, TaskTone) {
        switch status {
        case .needsYou: ("Needs you", .needsYou)
        case .broken: ("Broken", .broken)
        case .working: ("Working", .working)
        case .noProject, .opening, .nothing: ("Quiet", .idle)
        }
    }

    @ViewBuilder private func content(_ model: MenuBarPopoverModel) -> some View {
        switch model.status {
        case .needsYou:
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                RowCard(store: store, row: row, first: index == 0, open: open)
            }
        case .noProject:
            Text("No project open").font(.headline)
            Text("Open Workbench and choose a project.").font(.callout).foregroundStyle(.secondary)
        case .opening(let name):
            Text("Opening \(name)…").font(.headline)
        case .broken(let why):
            Label(why, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(Theme.red)
                .fixedSize(horizontal: false, vertical: true)
        case .working(let title):
            Text("Nothing needs you").font(.headline)
            Text("Working: \(title)").font(.callout).foregroundStyle(Theme.blue).lineLimit(2)
        case .nothing(let state):
            Text("Nothing needs you").font(.headline)
            if !state.isEmpty { Text(state).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let url = store.logURL {
                    Button("Event log") {
                        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .buttonStyle(.link).help("Opens the raw log file")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.link).keyboardShortcut("q")
            }
            Toggle("Pause notifications", isOn: Binding(get: { store.attention.paused }, set: { store.attention.paused = $0 }))
                .toggleStyle(.switch).controlSize(.small).font(.callout)
        }
    }

    private func open(_ route: AttentionRoute, sendBack: Bool) {
        store.show(route, project: store.project?.root.path)
        if sendBack { (store.actionError, store.sendingBack) = (nil, true) }
        openWindow(id: "main")
        WorkbenchApp.showWindow()
    }
}

private struct RowCard: View {
    var store: ProjectStore
    var row: PopoverRow
    var first: Bool
    var open: (AttentionRoute, Bool) -> Void

    var body: some View {
        let tone = row.item.tone
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: tone == .broken ? "xmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.color(for: tone))
                Text(row.item.title).font(.headline).lineLimit(1).truncationMode(.middle)
            }
            Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if let criteria = row.criteria {
                Text(criteria).font(.caption.weight(.semibold)).padding(.top, 2)
            }
            HStack(spacing: 8) {
                Button(row.item.route.isThread ? "Open review" : "Open task") { open(row.item.route, false) }
                    .modifier(PrimaryWhen(first))
                if row.canSendBack { Button("Send back…") { open(row.item.route, true) }.buttonStyle(.bordered) }
            }
            .padding(.top, 4)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color(for: tone).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

extension AttentionRoute {
    var isThread: Bool {
        if case .thread = self { return true }
        return false
    }
}
