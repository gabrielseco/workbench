import AppKit
import SwiftUI
import WorkbenchCore

/// The status item: the icon always, and the count only while something needs you, amber or (when something broke) red. The system
/// draws a menu bar item as a template, so the colour may be lost there: the count and the VoiceOver label carry the meaning.
struct MenuBarLabel: View {
    var store: ProjectStore

    var body: some View {
        let model = MenuBarLabelModel.make(items: store.attention.items)
        HStack(spacing: Space.xs) {
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
            denied: store.attention.notificationsDenied, deniedShown: store.attention.deniedWasShown,
            taskReadError: store.attention.taskReadError)
        VStack(alignment: .leading, spacing: Space.m) {
            header(model)
            content(model)
            if let note = model.tasksNote {
                Message(.warning, note, size: .caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.deniedNote {
                Label(note, systemImage: "bell.slash").textRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(Spacing.inset).frame(width: 320)
        .onDisappear { if model.deniedNote != nil { store.attention.sayDeniedOnce() } }
    }

    private func header(_ model: MenuBarPopoverModel) -> some View {
        HStack {
            SectionLabel((model.project ?? "Workbench").uppercased()).lineLimit(1).truncationMode(.middle)
            Spacer()
            let (word, tone) = pill(model.status)
            Text(word).pill(Theme.color(for: tone))
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
            // Many items scroll rather than grow the popover off the screen.
            ScrollView {
                VStack(spacing: Space.s) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        RowCard(store: store, row: row, first: index == 0, open: open)
                    }
                }
            }
            .frame(maxHeight: 380).fixedSize(horizontal: false, vertical: true)
        case .noProject:
            Text("No project open").textStyle(.heading)
            Text("Open Workbench and choose a project.").role(.detail)
        case .opening(let name):
            Text("Opening \(name)…").textStyle(.heading)
        case .broken(let why):
            Message(.error, why)
        case .working(let title):
            Text("Nothing needs you").textStyle(.heading)
            Text("Working: \(title)").textStyle(.callout, .blue).lineLimit(2)
        case .nothing(let state):
            Text("Nothing needs you").textStyle(.heading)
            if !state.isEmpty { Text(state).role(.detail).lineLimit(2) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s) {
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
                .toggleStyle(.switch).controlSize(.small).textStyle(.callout)
        }
    }

    private func open(_ route: AttentionRoute, sendBack: Bool) {
        store.openFromPopover(route, sendBack: sendBack)
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
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                StatusMark(tone == .broken ? .failed : .warning)
                Text(row.item.title).textStyle(.heading).lineLimit(1).truncationMode(.middle)
            }
            Text(row.detail).role(.caption).lineLimit(3)
            if let criteria = row.criteria {
                Text(criteria).textStyle(.captionStrong).padding(.top, Space.xxs)
            }
            HStack(spacing: Space.s) {
                Button(row.item.route.isThread ? "Open review" : "Open task") { open(row.item.route, false) }
                    .modifier(PrimaryWhen(first, size: .small))
                if row.canSendBack { Button("Send back…") { open(row.item.route, true) }.plainButton(size: .small) }
            }
            .padding(.top, Space.xs)
        }
        .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .callout(.tinted(Theme.color(for: tone)))
        .accessibilityElement(children: .contain)
    }
}

extension AttentionRoute {
    var isThread: Bool {
        if case .thread = self { return true }
        return false
    }
}
