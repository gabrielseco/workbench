import AppKit
import SwiftUI
import WorkbenchCore

/// What the new-thread screen's buttons allow, from what is typed and what is going on. Pure, so the rules are tested without a window.
struct NewThreadState: Equatable {
    var text = ""
    /// Screenshots staged, and images still being read.
    var screenshots = 0
    var pending = 0
    /// A draft or a reply is going.
    var busy = false

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A chat takes no screenshots: with any staged, Send waits and Do it now is the way.
    var canSend: Bool { !isBlank && !busy && screenshots == 0 && pending == 0 }
    var canDoItNow: Bool { !isBlank && !busy && pending == 0 }
    var canWriteAsGoal: Bool { canDoItNow }

    var sendHelp: String {
        screenshots > 0
            ? "A chat takes no screenshots: use Draft the goal."
            : "Starts a free chat. Nothing runs and nothing costs until you say so."
    }

    /// How many lines `text` takes in a box `width` points wide: its own lines and the ones a long line wraps into, at the body size.
    static func lineCount(_ text: String, width: CGFloat) -> Int {
        guard width > 0, !text.isEmpty else { return 1 }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let box = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
            attributes: [.font: font])
        return max(1, Int((box.height / lineHeight).rounded()))
    }

    /// The box's height for that many lines: roomy when empty (the artboard's composer is two lines tall), growing a line at a time to eight.
    static func editorHeight(lines: Int) -> CGFloat { 36 + CGFloat(min(8, max(2, lines))) * 18 }

    /// What a starter chip puts in the box.
    enum Starter: Equatable {
        case idea, bug
        var stub: String { self == .idea ? "I have an idea: " : "Fix this bug: " }
    }

    /// A starter fills an empty box and leaves words the person already typed alone.
    static func applying(_ starter: Starter, to text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? starter.stub : text
    }

    enum Key: Equatable { case send, doItNow, newline }

    /// Return sends, ⌘-Return is Do it now, Shift- or Option-Return a new line.
    static func key(shift: Bool, option: Bool, command: Bool) -> Key {
        if command { return .doItNow }
        return shift || option ? .newline : .send
    }
}

/// The heading and what it promises.
struct NewThreadHeading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What do you want to work on?").font(.title2.weight(.semibold))
            Text("Talk it through first, or hand it over. Nothing runs and nothing costs until you say so.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// What Send and Do it now each do, with the two names bold: a `LocalizedStringKey`, since two string literals joined with `+` would show
/// the asterisks.
struct NewThreadCaption: View {
    private static let text = LocalizedStringKey(
        "**Discuss first** opens a free chat; the goal is written after. **Draft the goal** skips the chat: "
            + "the goal agent drafts it from your words and you approve it. Nothing runs until you do.")

    var body: some View { Text(Self.text).font(.caption).foregroundStyle(.secondary) }
}

struct NewThreadHint: View {
    var body: some View {
        Text("Drop a screenshot on the window to start one").font(.caption).foregroundStyle(Theme.fg3)
    }
}

/// The two starters that have something behind them.
struct NewThreadChips: View {
    var brainstorm: () -> Void
    var screenshot: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            chip("Brainstorm an idea", brainstorm)
            chip("Fix a bug from a screenshot", screenshot)
        }
    }

    private func chip(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.panel, in: Capsule()).overlay(Capsule().stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }
}

/// The new-thread screen (P22 design parity 6): what to work on, a composer, and three ways to go on, in the feed's column.
struct NewThreadScreen: View {
    var store: ProjectStore
    @State private var staging = AttachmentStaging()
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    /// The panel's width as it is drawn (the column, or less at a narrow window): the text box is that less its padding and inset, and
    /// it is sized to the lines the text wraps into at that width.
    @State private var panelWidth: CGFloat = FeedLayout.maxColumn
    private var composerWidth: CGFloat { max(0, panelWidth - 2 * 14 - 12) }

    private var busy: Bool { store.drafting || store.chatReplying }

    private var state: NewThreadState {
        NewThreadState(text: store.newThreadText, screenshots: staging.items.count, pending: staging.pending, busy: busy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    NewThreadHeading()
                    messages
                    composer
                    caption
                    NewThreadChips(brainstorm: { start(.idea) }, screenshot: { start(.bug); chooseImages() }).disabled(busy)
                    NewThreadHint().padding(.top, 12)
                }
                .frame(maxWidth: FeedLayout.maxColumn, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 36).frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand { if !busy { store.closeNewThread() } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy else { return false }
            Task { await staging.add(files: urls) }
            return true
        }
        .onAppear { watchPaste() }
        .onDisappear {
            pasteMonitor.map(NSEvent.removeMonitor)
            pasteMonitor = nil
            staging.clear()
        }
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New thread").font(.title3.weight(.semibold))
            PhaseRow(steps: PhaseRow.newThreadSteps)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 12)
    }

    /// A refusal asks the person to change something: amber, with their text kept. A project with no goal agent can name one.
    @ViewBuilder private var messages: some View {
        if let problem = staging.problem { MessageRow(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, text: problem) }
        if store.goalAgentOff {
            VStack(alignment: .leading, spacing: 8) {
                MessageRow(
                    symbol: "exclamationmark.triangle.fill", tint: Theme.amber,
                    text: "Drafting needs a goal agent, and this project's config names none. Pick who drafts: it adds "
                        + "[agents.goal] to .workbench/config.toml and drafts this goal.")
                HStack {
                    ForEach([AgentProviderID.claude, .codex], id: \.rawValue) { provider in
                        Button("Draft with \(provider.rawValue.capitalized)") {
                            Task { await store.draftNewThread(naming: provider, attachments: staging.urls) }
                        }
                        .disabled(!state.canDoItNow)
                    }
                }
            }
        } else if let error = store.actionError {
            MessageRow(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, text: error)
        }
    }

    private var composer: some View {
        let state = state
        return VStack(alignment: .leading, spacing: 0) {
            editor(state).padding(.horizontal, 14).padding(.top, 12)
            if !staging.items.isEmpty { thumbnails.padding(.horizontal, 14).padding(.top, 8) }
            Divider().padding(.top, 10)
            HStack(spacing: 10) {
                Button(action: chooseImages) {
                    Image(systemName: "plus").frame(width: 26, height: 26)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).disabled(busy).accessibilityLabel("Add screenshots…").help("Add screenshots")
                Text("Paste or drop screenshots.").font(.caption).foregroundStyle(.secondary)
                if staging.pending > 0 { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                    Text(store.drafting ? "Drafting the goal…" : "Waiting for the reply…").font(.callout)
                        .foregroundStyle(Theme.blue)
                    Button("Stop") {
                        if store.drafting { store.stopDrafting() } else { store.stopChat() }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button { Task { await doItNow() } } label: { Self.labelled("Draft the goal", "⌘↵") }
                        .plainButton().keyboardShortcut(.return, modifiers: .command).disabled(!state.canDoItNow)
                        .help("Skips the conversation: the goal agent drafts a goal from your words for you to approve")
                    Button { Task { await send() } } label: { Self.labelled("Discuss first", "↵") }
                        .primaryButton().disabled(!state.canSend).help(state.sendHelp)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(focused ? Theme.blue.opacity(0.6) : Theme.line, lineWidth: focused ? 1.5 : 1))
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { panelWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { panelWidth = proxy.size.width }
            }
        }
    }

    private func editor(_ state: NewThreadState) -> some View {
        PlaceholderTextEditor(
            text: Binding(get: { store.newThreadText }, set: { store.newThreadText = $0 }),
            placeholder: "Describe the change, the bug or the idea.", font: .body, hidesScroller: true,
            showsPlaceholder: state.isBlank, accessibilityLabel: "What do you want to work on?", focus: $focused,
            onReturn: { press in
                let key = NewThreadState.key(
                    shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option),
                    command: press.modifiers.contains(.command))
                // A new line is the text box's own; ⌘-Return is the Do it now button's shortcut.
                guard key == .send else { return .ignored }
                if state.canSend { Task { await send() } }
                return .handled
            }
        )
        .frame(height: NewThreadState.editorHeight(lines: NewThreadState.lineCount(state.text, width: composerWidth)))
        .disabled(busy)
    }

    private var thumbnails: some View {
        HStack(spacing: 8) {
            ForEach(Array(staging.items.enumerated()), id: \.element.id) { index, item in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = item.thumbnail { Image(nsImage: image).resizable().scaledToFill() } else {
                            Theme.grey.opacity(0.3)
                        }
                    }
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                    Button { staging.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Remove screenshot \(index + 1)").padding(2)
                }
            }
            Spacer()
        }
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline) {
            NewThreadCaption()
            Spacer(minLength: 12)
            Button("Use my text as the goal") { Task { await writeAsGoal() } }
                .buttonStyle(.link).font(.caption).disabled(!state.canWriteAsGoal)
                .help("Keeps your words as the goal, with no criteria and no agent; you approve it next")
        }
    }

    /// A button's name and its key, as the artboard draws them.
    private static func labelled(_ title: String, _ key: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(key).font(.caption).opacity(0.7)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }

    /// A `LocalizedStringKey`, so the two names are bold: two string literals joined with `+` would show the asterisks.
    private func send() async {
        if await store.sendNewThread() { staging.clear() }
    }

    private func doItNow() async {
        if await store.draftNewThread(attachments: staging.urls) { staging.clear() }
    }

    private func writeAsGoal() async {
        if await store.quickNewThread(attachments: staging.urls) { staging.clear() }
    }

    private func start(_ starter: NewThreadState.Starter) {
        store.newThreadText = NewThreadState.applying(starter, to: store.newThreadText)
        focused = true
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { Task { await staging.add(files: panel.urls) } }
    }

    /// ⌘V while the screen is up takes a screenshot off the clipboard; text on the clipboard still goes to the text box.
    private func watchPaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [staging, store] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "v", !store.drafting, !store.chatReplying,
                AttachmentStaging.wantsImages(.general)
            else { return event }
            Task { await staging.add(from: .general) }
            return nil
        }
    }
}
