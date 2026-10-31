import AppKit
import SwiftUI
import WorkbenchCore

/// Asks what needs to be done, in a card you write in: the text is the point, the rest is small. It opens on a quick goal (the text
/// as written, no criteria); Advanced has the goal agent draft criteria from the same text. It stays up while it works and keeps the
/// text when the goal does not come out.
struct NewGoalPopover: View {
    var store: ProjectStore
    @State private var form = NewGoalForm()
    @State private var staging = AttachmentStaging()
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    private var project: String { store.project?.root.lastPathComponent ?? "this project" }
    /// The goal agent is asked for only in Advanced: a quick goal needs none.
    private var agentOff: Bool { form.mode == .advanced && store.goalAgentOff }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            modes.padding(.top, 14)
            writing.padding(.top, 12)
            attachments.padding(.top, 20)
            messages
            footer.padding(.top, 26)
        }
        .overlayCard()
        .onExitCommand { if !store.drafting { close() } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !store.drafting else { return false }
            Task { await staging.add(files: urls) }
            return true
        }
        .onAppear {
            store.actionError = nil
            watchPaste()
        }
        // An overlay is not yet in the window when `onAppear` runs, and focus set then is lost: one tick later it takes.
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
        }
        .onDisappear {
            pasteMonitor.map(NSEvent.removeMonitor)
            pasteMonitor = nil
            staging.clear()
        }
    }

    private func close() { store.namingGoal = false }

    private var header: some View {
        HStack {
            Text("New goal in \(project)".uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.9).foregroundStyle(.secondary)
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.drafting)
                .accessibilityLabel("Close the new goal panel")
        }
    }

    /// Quick or Advanced. The text stays as it is either way.
    private var modes: some View {
        Picker("Kind of goal", selection: $form.mode) {
            ForEach(NewGoalForm.Mode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .disabled(store.drafting)
        .help("Quick keeps your words as the goal. Advanced has the goal agent draft criteria that the judge can check.")
    }

    private var placeholder: String {
        form.mode == .quick
            ? "What needs to be done? A sentence or two is enough."
            : "What needs to be done? Describe the change, the bug or the idea, and say how you will know it worked."
    }

    private var writing: some View {
        TextEditor(text: $form.request)
            .font(.system(size: 17, design: .serif)).lineSpacing(6)
            .focused($focused).scrollContentBackground(.hidden)
            .frame(height: 170)
            .disabled(store.drafting)
            .overlay(alignment: .topLeading) {
                if form.request.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 17, design: .serif)).lineSpacing(6)
                        .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
    }

    /// The screenshots added so far, and the ways to add one: paste, drop or the button.
    private var attachments: some View {
        HStack(spacing: 10) {
            ForEach(Array(staging.items.enumerated()), id: \.element.id) { index, item in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = item.thumbnail {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Theme.grey.opacity(0.3)
                        }
                    }
                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                    if !store.drafting {
                        Button { staging.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Remove screenshot \(index + 1)").padding(3)
                    }
                }
            }
            if !store.drafting, staging.items.count < GoalAttachments.maxCount {
                Button { chooseImages() } label: {
                    Text("+ screenshot").font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Theme.grey.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain).accessibilityLabel("Add screenshots…")
            }
            if staging.pending > 0 { ProgressView().controlSize(.small) }
            Text(staging.items.isEmpty && staging.pending == 0 ? "Paste or drop screenshots here" : "")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var messages: some View {
        if let problem = staging.problem {
            Text(problem).font(.callout).foregroundStyle(Theme.red).padding(.top, 14)
        }
        if agentOff {
            Text(
                "Drafting needs a goal agent, and this project's config names none. Pick who drafts: it adds "
                    + "[agents.goal] to .workbench/config.toml and drafts this goal."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        } else if let error = store.actionError {
            Text(error).font(.callout).foregroundStyle(Theme.red).padding(.top, 14)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if store.drafting {
                ProgressView().controlSize(.small)
                Text(form.busyText).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(form.note)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if store.drafting {
                if form.mode == .advanced { Button("Stop") { store.stopDrafting() } }
            } else {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                if agentOff {
                    ForEach([AgentProviderID.claude, .codex], id: \.rawValue) { provider in
                        Button("Draft with \(provider.rawValue.capitalized)") {
                            Task {
                                if await store.enableGoalDrafting(
                                    provider, request: form.request, attachments: staging.urls) { close() }
                            }
                        }
                        .disabled(staging.pending > 0)
                    }
                } else {
                    Button("Create") {
                        Task {
                            let made = await store.createGoal(form, attachments: staging.urls)
                            if made { close() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command).disabled(form.isEmpty || staging.pending > 0)
                }
            }
        }
    }

    /// ⌘V while the popover is up takes a screenshot off the clipboard. The text editor cannot: to it an image is nothing to paste,
    /// so the command never reaches a handler of ours. Text on the clipboard still goes to the text editor.
    private func watchPaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [staging, store] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "v", !store.drafting,
                AttachmentStaging.wantsImages(.general)
            else { return event }
            Task { await staging.add(from: .general) }
            return nil
        }
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { Task { await staging.add(files: panel.urls) } }
    }
}
