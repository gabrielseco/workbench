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
    var canSend: Bool { !isBlank && !busy && pending == 0 }
    var canDoItNow: Bool { !isBlank && !busy && pending == 0 }
    var canWriteAsGoal: Bool { canDoItNow }

    var sendHelp: String {
        screenshots > 0
            ? "Starts a free chat. The agent sees your screenshots. Nothing runs and nothing costs until you say so."
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

    enum Key: Equatable { case send, doItNow, newline }

    /// Return sends, ⌘-Return is Do it now, Shift- or Option-Return a new line.
    static func key(shift: Bool, option: Bool, command: Bool) -> Key {
        if command { return .doItNow }
        return shift || option ? .newline : .send
    }
}

/// The heading and what it promises.
struct NewThreadHeading: View {
    /// What a chat and a drafted goal talk to: nil while the config is not read, `.some(nil)` when the project has no goal agent.
    var agent: String??

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("What do you want to work on?").textStyle(.title)
            Text("Talk it through first, or hand it over. Nothing runs and nothing costs until you say so.")
                .role(.detail)
            if let agent {
                Text(agent.map { "Chat and drafting use \($0)." } ?? "No goal agent is set, so chat and drafting are off.")
                    .role(.caption)
            }
        }
    }
}

/// What the three ways on each do, one line each in the buttons' order. The third name is the button itself: a quick goal from the words.
struct NewThreadCaption: View {
    var canUseText = true
    var useText: () -> Void = {}

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Discuss first", "Talk it through with the agent; the goal comes after. Free.")
            row("Draft the goal", "The agent writes the goal from your words, with criteria. You approve it.")
            GridRow {
                // Blue with an arrow, and only faded while the box is empty, so it reads as a link in every state.
                Button(action: useText) { Text("Use my text as the goal \(Image(systemName: "arrow.right"))") }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue).opacity(canUseText ? 1 : 0.5)
                    .textStyle(.captionStrong).disabled(!canUseText)
                    .accessibilityLabel("Use my text as the goal")
                    .help("Keeps your words as the goal, with no criteria and no agent; you approve it next")
                Text("Your words become the goal as typed. No agent, no criteria. Free.")
            }
        }
        .textRole(.caption)
    }

    private func row(_ name: String, _ what: String) -> some View {
        GridRow {
            Text(name).fontWeight(.semibold).foregroundStyle(.primary)
            Text(what)
        }
    }
}

/// The new-thread screen (P22 design parity 6): what to work on, a composer, and three ways to go on, in the feed's column.
struct NewThreadScreen: View {
    var store: ProjectStore
    @State private var staging = AttachmentStaging()
    @FocusState private var focused: Bool

    /// The panel's width as it is drawn (the column, or less at a narrow window): the text box is that less its padding and inset, and
    /// it is sized to the lines the text wraps into at that width.
    @State private var panelWidth: CGFloat = FeedLayout.maxColumn
    private var composerWidth: CGFloat { max(0, panelWidth - 2 * 14 - 12) }

    private var busy: Bool { store.drafting || store.chatReplying }

    /// What the heading says about the agent: nil until the config is read, `.some(nil)` when the project has no goal agent.
    private var headingAgent: String?? {
        if let setup = store.agentSetup { return .some(AgentSetup.chatAgent(for: setup)) }
        return store.agentConfigMissing ? .some(nil) : nil
    }

    private var state: NewThreadState {
        NewThreadState(text: store.newThreadText, screenshots: staging.items.count, pending: staging.pending, busy: busy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    NewThreadHeading(agent: headingAgent)
                    messages
                    composer
                    caption
                }
                .frame(maxWidth: FeedLayout.maxColumn, alignment: .leading)
                .padding(.horizontal, Spacing.gutter).padding(.vertical, Space.huge).frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand { if !busy { store.closeNewThread() } }
        .screenshotDrop(staging, allowed: !busy)
        .pastesScreenshots({ staging }, allowed: { [store] in !store.drafting && !store.chatReplying })
        .onDisappear { staging.clear() }
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            focused = true
        }
        .task { await store.refreshAgentSetup() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("New thread").textStyle(.section)
            PhaseRow(steps: PhaseRow.newThreadSteps)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.gutter).padding(.top, Space.l).padding(.bottom, Space.m)
    }

    /// A refusal asks the person to change something: amber, with their text kept. A project with no goal agent can name one.
    @ViewBuilder private var messages: some View {
        if let problem = staging.problem { Message(.warning, problem) }
        if store.goalAgentOff {
            VStack(alignment: .leading, spacing: Space.s) {
                Message(
                    .warning,
                    "Drafting needs a goal agent, and this project's config names none. Pick who drafts: it adds "
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
            Message(.warning, error)
        }
    }

    private var composer: some View {
        let state = state
        return VStack(alignment: .leading, spacing: 0) {
            editor(state).padding(.horizontal, Spacing.inset).padding(.top, Space.m)
            if !staging.items.isEmpty {
                StagedThumbnails(staging: staging).padding(.horizontal, Spacing.inset).padding(.top, Space.s)
            }
            Divider().padding(.top, Space.m)
            HStack(spacing: Space.m) {
                AddScreenshotsButton(staging: staging, disabled: busy)
                Text("Paste or drop screenshots.").role(.caption)
                if staging.pending > 0 { Spinner() }
                Spacer(minLength: Space.s)
                if busy {
                    BusyLine(
                        store.drafting ? "Drafting the goal…" : "Waiting for the reply…", tone: .working,
                        stop: .init(title: "Stop") { if store.drafting { store.stopDrafting() } else { store.stopChat() } })
                } else {
                    Button { Task { await doItNow() } } label: { Self.labelled("Draft the goal", "⌘↵") }
                        .plainButton(size: .regular).keyboardShortcut(.return, modifiers: .command).disabled(!state.canDoItNow)
                        .help("Skips the conversation: the goal agent drafts a goal from your words for you to approve")
                    Button { Task { await send() } } label: { Self.labelled("Discuss first", "↵") }
                        .primaryButton().disabled(!state.canSend).help(state.sendHelp)
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.m)
        }
        .card(stroke: focused ? Theme.blue.opacity(0.6) : Theme.line, strokeWidth: focused ? 1.5 : 1)
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
            placeholder: "Describe the change, the bug or the idea.", style: .body, hidesScroller: true,
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

    private var caption: some View {
        NewThreadCaption(canUseText: state.canWriteAsGoal) { Task { await writeAsGoal() } }
    }

    /// A button's name and its key, as the artboard draws them.
    private static func labelled(_ title: String, _ key: String) -> some View {
        HStack(spacing: Space.s) {
            Text(title)
            Text(key).textStyle(.caption).opacity(0.7)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }

    /// A `LocalizedStringKey`, so the two names are bold: two string literals joined with `+` would show the asterisks.
    private func send() async {
        if await store.sendNewThread(attachments: staging.urls) { staging.clear() }
    }

    private func doItNow() async {
        if await store.draftNewThread(attachments: staging.urls) { staging.clear() }
    }

    private func writeAsGoal() async {
        if await store.quickNewThread(attachments: staging.urls) { staging.clear() }
    }
}
